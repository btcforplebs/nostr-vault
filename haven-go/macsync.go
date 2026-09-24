package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"log/slog"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/barrydeen/haven/internal/negsync"
	"github.com/fiatjaf/eventstore"
	"github.com/nbd-wtf/go-nostr"
	"github.com/spf13/afero"
)

// ─── Mac relay: the always-on Haven a phone can pull from ───────────────────
//
// MAC_RELAY_URL names another Haven instance (normally the owner's Mac) that
// runs 24/7. Its outbox (the base URL) is a seed relay (loadConfig) and its
// inbox (base + "/inbox") an inbox-only relay (subscribeInboxAndChat), so the
// regular catch-up rounds cover it like any other relay. On top of that, the
// first time a given Mac URL is seen, its entire history is copied once
// (macBackfiller) — the rolling catch-up window only reaches back
// SyncWindowDays.

// macRelayBase normalizes a MAC_RELAY_URL value to the Mac's outbox URL.
func macRelayBase(raw string) string {
	return strings.TrimRight(strings.TrimSpace(raw), "/")
}

// macRelayURLs returns the Mac relay's outbox and inbox URLs, or two empty
// strings when no Mac relay is configured.
func macRelayURLs() (base, inbox string) {
	base = macRelayBase(config.MacRelayURL)
	if base == "" {
		return "", ""
	}
	return base, base + "/inbox"
}

// macSyncStatus is persisted after every backfill so the app can show it and
// so a completed backfill isn't repeated on every launch.
type macSyncStatus struct {
	MacURL     string `json:"mac_url"`
	State      string `json:"state"`    // running | done | incomplete | failed
	Method     string `json:"method"`   // negentropy | paged
	Posts      int    `json:"posts"`    // owner events newly stored
	Mentions   int    `json:"mentions"` // tagged events newly stored
	Missing    int    `json:"missing"`  // still missing after the final pass; -1 = not measurable (paged)
	Error      string `json:"error,omitempty"`
	StartedAt  int64  `json:"started_at"`
	UpdatedAt  int64  `json:"updated_at,omitempty"` // heartbeat while running; a stale one means the copy died
	FinishedAt int64  `json:"finished_at,omitempty"`
}

const macSyncStatusPath = "mac_sync_status.json"

// macHeartbeat is how often a running copy refreshes UpdatedAt. The app treats
// "running" with a heartbeat older than a few of these as a copy that died.
const macHeartbeat = 20 * time.Second

func loadMacSyncStatus() macSyncStatus {
	var st macSyncStatus
	if data, err := afero.ReadFile(fs, macSyncStatusPath); err == nil {
		_ = json.Unmarshal(data, &st)
	}
	return st
}

func saveMacSyncStatus(st macSyncStatus) {
	data, err := json.Marshal(st)
	if err != nil {
		return
	}
	if err := afero.WriteFile(fs, macSyncStatusPath, data, 0o644); err != nil {
		slog.Warn("could not write mac sync status", "err", err)
	}
}

// macBackfillEpoch is the lower edge of the sliced walk. Nothing real predates
// Nostr's first events (late 2020); the first slice has no lower bound anyway,
// so a backdated event before this date is still copied.
var macBackfillEpoch = time.Date(2020, 11, 1, 0, 0, 0, 0, time.UTC)

// macBackfillSlice bounds how much local history one reconciliation
// materializes: BuildVector decodes every local event in the filter, and a
// whole-history vector on a phone is exactly the memory spike to avoid.
const macBackfillSlice = 90 * 24 * time.Hour

// macBackfillSessionTimeout bounds one negentropy session (one slice) or one
// page of the paged fallback.
const macBackfillSessionTimeout = 90 * time.Second

// macPageLimit is the page size for the paged fallback. Paging stops on an
// empty page, not a short one, so a relay capping below this is still walked
// to the end.
const macPageLimit = 500

// macMaxCopyPasses bounds the reconcile-until-converged loop. On a real Mac
// relay one pass left a couple dozen of ~26k events unlisted; the second pass
// found and stored them.
const macMaxCopyPasses = 5

// macBackfiller copies the Mac's full history. It has its own inbox store and
// notifier (sharing the DBs, tombstones and reject cache with the catch-up
// loop) because it runs on its own goroutine, alongside catch-up rounds.
type macBackfiller struct {
	pTags      []string
	inboxNeg   nostr.RelayStore
	outboxNeg  nostr.RelayStore
	wdbInbox   eventstore.RelayWrapper
	wdbChat    eventstore.RelayWrapper
	wdbOutbox  eventstore.RelayWrapper
	notifier   *batchNotifier
	rejects    *tempRejects
	now        func() time.Time
	negEnabled bool

	running atomic.Bool
}

// macTarget is one side of the copy: the Mac's outbox into ours, or its inbox
// into our inbox/chat.
type macTarget struct {
	name     string // "posts" | "mentions"
	url      string
	store    nostr.RelayStore
	filter   nostr.Filter // without since/until
	isStored func(ctx context.Context, ev *nostr.Event) bool
}

func (b *macBackfiller) targets(base, inbox string) []macTarget {
	return []macTarget{
		{"posts", base, b.outboxNeg, nostr.Filter{Authors: b.pTags},
			func(ctx context.Context, ev *nostr.Event) bool { return storeHas(ctx, b.wdbOutbox, ev) }},
		{"mentions", inbox, b.inboxNeg, nostr.Filter{Tags: nostr.TagMap{"p": b.pTags}},
			func(ctx context.Context, ev *nostr.Event) bool {
				return storeHas(ctx, b.wdbInbox, ev) || storeHas(ctx, b.wdbChat, ev)
			}},
	}
}

// storeHas reports whether ev itself (not a stub) is in db.
func storeHas(ctx context.Context, db eventstore.RelayWrapper, ev *nostr.Event) bool {
	ts := ev.CreatedAt
	evs, err := db.QuerySync(ctx, nostr.Filter{IDs: []string{ev.ID}, Since: &ts, Until: &ts})
	return err == nil && len(evs) > 0
}

// slices returns [since, until] windows covering all time, oldest first. A nil
// bound is open.
func (b *macBackfiller) slices() [][2]*nostr.Timestamp {
	var out [][2]*nostr.Timestamp
	epoch := nostr.Timestamp(macBackfillEpoch.Unix())
	out = append(out, [2]*nostr.Timestamp{nil, &epoch})
	for start := macBackfillEpoch; start.Before(b.now()); start = start.Add(macBackfillSlice) {
		s := nostr.Timestamp(start.Unix()) + 1 // windows are inclusive on both ends
		var u *nostr.Timestamp
		if end := start.Add(macBackfillSlice); end.Before(b.now()) {
			e := nostr.Timestamp(end.Unix())
			u = &e
		}
		out = append(out, [2]*nostr.Timestamp{&s, u})
	}
	return out
}

// runIfNeeded copies the Mac's full history once per Mac URL. A finished copy
// is not repeated; an incomplete or failed one is retried on the next launch.
// force re-runs it regardless (the app's "Check sync with Mac"). Never runs
// twice at once.
func (b *macBackfiller) runIfNeeded(ctx context.Context, force bool) {
	base, inbox := macRelayURLs()
	if base == "" {
		return
	}
	if !b.running.CompareAndSwap(false, true) {
		return
	}
	defer b.running.Store(false)
	prev := loadMacSyncStatus()
	if !force && prev.MacURL == base && prev.State == "done" {
		return
	}
	st := b.run(ctx, base, inbox)
	if ctx.Err() != nil {
		return // relay stopping mid-copy: the heartbeat goes stale, retry next launch
	}
	saveMacSyncStatus(st)
}

// loop runs the copy once after startup, then again on every check request.
func (b *macBackfiller) loop(ctx context.Context, checks <-chan struct{}) {
	b.runIfNeeded(ctx, false)
	for {
		select {
		case <-ctx.Done():
			return
		case <-checks:
			b.runIfNeeded(ctx, true)
		}
	}
}

func (b *macBackfiller) run(ctx context.Context, base, inbox string) macSyncStatus {
	st := macSyncStatus{MacURL: base, State: "running", Method: "negentropy", StartedAt: b.now().Unix(), UpdatedAt: b.now().Unix()}
	saveMacSyncStatus(st)
	log.Println("🖥️ copying full history from Mac relay", base)

	// Heartbeat: lets the app tell a live copy from one whose process died.
	hbCtx, stopHB := context.WithCancel(ctx)
	var hbWG sync.WaitGroup
	hbWG.Add(1)
	go func() {
		defer hbWG.Done()
		t := time.NewTicker(macHeartbeat)
		defer t.Stop()
		for {
			select {
			case <-hbCtx.Done():
				return
			case <-t.C:
				hb := st
				hb.UpdatedAt = b.now().Unix()
				saveMacSyncStatus(hb)
			}
		}
	}()
	defer func() { stopHB(); hbWG.Wait() }()

	var errs []string
	missing, posts, mentions := 0, 0, 0
	measurable := true
	for _, t := range b.targets(base, inbox) {
		copied, left, err := b.copyTarget(ctx, t)
		if ctx.Err() != nil {
			return st
		}
		if t.name == "posts" {
			posts = copied
		} else {
			mentions = copied
		}
		if left < 0 {
			measurable = false
		} else {
			missing += left
		}
		if err != nil {
			errs = append(errs, t.name+": "+err.Error())
		}
	}
	// Old backlog doesn't notify (isNotifyableAge), and this isn't a return
	// from absence either: end the batch without a summary.
	b.notifier.flush(false)

	stopHB()
	hbWG.Wait()
	st.Posts, st.Mentions = posts, mentions
	st.FinishedAt = b.now().Unix()
	st.UpdatedAt = st.FinishedAt
	st.Missing = missing
	if !measurable {
		st.Missing = -1
		st.Method = "paged"
	}
	switch {
	case len(errs) > 0 && posts+mentions == 0:
		st.State = "failed"
	case len(errs) > 0 || missing > 0:
		st.State = "incomplete"
	default:
		st.State = "done"
	}
	st.Error = strings.Join(errs, "; ")
	log.Printf("🖥️ Mac relay copy %s: %d posts, %d mentions, missing %d (%s)", st.State, st.Posts, st.Mentions, st.Missing, st.Method)
	return st
}

// errNotConverged: every pass still stored something new.
var errNotConverged = fmt.Errorf("still finding new events after %d passes", macMaxCopyPasses)

// copyTarget copies one side, repeating the reconciliation until a fresh pass
// stores nothing, and reports that pass's unresolved count: IDs the Mac listed
// that the phone has neither stored, deliberately rejected, nor superseded
// with a newer version. left is -1 when the Mac has no NIP-77 and the paged
// fallback ran (a page walk can't tell "missing" from "rejected").
//
// The shared NIP-77 capability cache is only ever marked supported here, never
// unsupported: one refused slice of a one-time copy must not switch the
// regular catch-up off NIP-77 for a day. For the same reason the copy always
// tries NIP-77 first instead of trusting a cached "unsupported".
func (b *macBackfiller) copyTarget(ctx context.Context, t macTarget) (copied, left int, err error) {
	if b.negEnabled {
		for pass := 0; pass < macMaxCopyPasses; pass++ {
			acc := &accountingStore{RelayStore: t.store, isStored: t.isStored}
			remote, slice, perr := b.reconcileAll(ctx, t, acc)
			copied += int(acc.stored.Load())
			if perr != nil {
				// Only a refusal of the very first session means "this Mac has
				// no usable NIP-77". Anything later is a failed copy.
				if pass == 0 && slice == 0 && (errors.Is(perr, negsync.ErrUnsupported) || errors.Is(perr, negsync.ErrRefused)) {
					log.Println("ℹ️ Mac relay has no usable NIP-77, copying page by page:", t.url, perr)
					n, pgErr := b.pageAll(ctx, t)
					return copied + n, -1, pgErr
				}
				return copied, 0, perr
			}
			markNegentropySupported(t.url)
			left = max(0, remote-int(acc.stored.Load())-int(acc.accounted.Load()))
			// Only a fresh pass that stored nothing is a real check: on a real
			// Mac relay the first pass did not even list some events that the
			// second pass then found and stored.
			if acc.stored.Load() == 0 {
				if left > 0 {
					// IDs the Mac listed but never served can't be named here;
					// only ones it sent that could not be placed.
					log.Printf("🖥️ %s: %d unresolved; sent but not placed: %v", t.name, left, acc.unresolvedIDs())
				}
				return copied, left, nil
			}
		}
		return copied, left, errNotConverged
	}
	n, pgErr := b.pageAll(ctx, t)
	return n, -1, pgErr
}

// reconcileAll runs one Down reconciliation per time slice into store and
// returns the number of IDs the Mac had that we lacked at the start of each,
// and on error the index of the slice that failed.
func (b *macBackfiller) reconcileAll(ctx context.Context, t macTarget, store nostr.RelayStore) (remote, slice int, err error) {
	for i, sl := range b.slices() {
		if ctx.Err() != nil {
			return remote, i, ctx.Err()
		}
		f := t.filter
		f.Since, f.Until = sl[0], sl[1]
		sctx, cancel := context.WithTimeout(ctx, macBackfillSessionTimeout)
		stats, serr := negsync.Sync(sctx, store, t.url, f, negsync.Down)
		cancel()
		remote += stats.RemoteOnly
		if serr != nil {
			return remote, i, serr
		}
	}
	return remote, 0, nil
}

// accountingStore wraps a sync store and classifies every event the Mac sends:
// stored (newly in the DB), accounted (listed as had afterwards without being
// newly stored: a deliberate reject — tombstone or cached WoT stub — or already
// present), or superseded (a replaceable version older than one we keep).
// Anything else stays unresolved. Publish runs concurrently from negsync's
// batch workers.
type accountingStore struct {
	nostr.RelayStore
	isStored  func(ctx context.Context, ev *nostr.Event) bool
	stored    atomic.Int64
	accounted atomic.Int64

	mu         sync.Mutex
	unresolved []string // first few events that could not be placed, for the log
}

func (s *accountingStore) Publish(ctx context.Context, ev nostr.Event) error {
	before := s.isStored(ctx, &ev)
	err := s.RelayStore.Publish(ctx, ev)
	switch {
	case !before && s.isStored(ctx, &ev):
		s.stored.Add(1)
	case before || s.listed(ctx, &ev) || s.superseded(ctx, &ev):
		s.accounted.Add(1)
	default:
		s.mu.Lock()
		if len(s.unresolved) < 10 {
			s.unresolved = append(s.unresolved, fmt.Sprintf("%s kind=%d at=%d err=%v", ev.ID, ev.Kind, ev.CreatedAt, err))
		}
		s.mu.Unlock()
	}
	return err
}

func (s *accountingStore) unresolvedIDs() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.unresolved...)
}

// listed reports whether the local vector lists ev — including tombstone and
// reject stubs, which QuerySync appends. Bounded to ev's own second so the
// stub lists stay small.
func (s *accountingStore) listed(ctx context.Context, ev *nostr.Event) bool {
	ts := ev.CreatedAt
	evs, err := s.RelayStore.QuerySync(ctx, nostr.Filter{IDs: []string{ev.ID}, Since: &ts, Until: &ts})
	if err != nil {
		return false
	}
	for _, e := range evs {
		if e.ID == ev.ID {
			return true
		}
	}
	return false
}

// superseded reports whether ev is a replaceable or addressable event the store
// keeps a newer version of, so it can never be stored and isn't missing.
func (s *accountingStore) superseded(ctx context.Context, ev *nostr.Event) bool {
	if !nostr.IsReplaceableKind(ev.Kind) && !nostr.IsAddressableKind(ev.Kind) {
		return false
	}
	f := nostr.Filter{Authors: []string{ev.PubKey}, Kinds: []int{ev.Kind}, Since: &ev.CreatedAt}
	if nostr.IsAddressableKind(ev.Kind) {
		f.Tags = nostr.TagMap{"d": []string{ev.Tags.GetD()}}
	}
	evs, err := s.RelayStore.QuerySync(ctx, f)
	if err != nil {
		return false
	}
	for _, e := range evs {
		if e.PubKey == ev.PubKey && e.Kind == ev.Kind && e.ID != ev.ID &&
			(e.CreatedAt > ev.CreatedAt || (e.CreatedAt == ev.CreatedAt && e.ID < ev.ID)) {
			return true
		}
	}
	return false
}

// pageAll walks the Mac relay newest to oldest with an until cursor over one
// connection. It stops on an empty page rather than a short one, so it can't
// mistake a relay's own result cap for the end of history, and any page that
// doesn't end in EOSE — timeout, CLOSED, dropped connection — is an error, so
// a cut-short walk is never reported as a finished copy.
func (b *macBackfiller) pageAll(ctx context.Context, t macTarget) (int, error) {
	r, err := nostr.RelayConnect(ctx, t.url)
	if err != nil {
		return 0, err
	}
	defer r.Close()

	var until *nostr.Timestamp
	copied := 0
	for {
		if ctx.Err() != nil {
			return copied, ctx.Err()
		}
		f := t.filter
		f.Limit = macPageLimit
		f.Until = until
		n, oldest, stored, perr := b.page(ctx, r, t, f)
		copied += stored
		if perr != nil {
			return copied, perr
		}
		if n == 0 {
			return copied, nil
		}
		// Step past this page. If every event in it shared one second, move
		// one second back so the walk can't spin on the same page forever.
		next := oldest
		if until != nil && next >= *until {
			next = *until - 1
		}
		until = &next
	}
}

// page fetches one page and stores what it gets. It returns an error unless
// the relay ended the page with EOSE.
func (b *macBackfiller) page(ctx context.Context, r *nostr.Relay, t macTarget, f nostr.Filter) (n int, oldest nostr.Timestamp, stored int, err error) {
	pctx, cancel := context.WithTimeout(ctx, macBackfillSessionTimeout)
	defer cancel()
	sub, err := r.Subscribe(pctx, nostr.Filters{f})
	if err != nil {
		return 0, 0, 0, err
	}
	defer sub.Unsub()
	for {
		select {
		case ev, ok := <-sub.Events:
			if !ok {
				return n, oldest, stored, errors.New("subscription ended before EOSE")
			}
			n++
			if oldest == 0 || ev.CreatedAt < oldest {
				oldest = ev.CreatedAt
			}
			before := t.isStored(ctx, ev)
			if t.name == "posts" {
				processOwnerEvent(ctx, nostr.RelayEvent{Event: ev, Relay: r}, b.wdbOutbox)
			} else {
				processInboxEvent(ctx, nostr.RelayEvent{Event: ev, Relay: r}, b.wdbInbox, b.wdbChat, b.notifier, b.rejects)
			}
			if !before && t.isStored(ctx, ev) {
				stored++
			}
		case <-sub.EndOfStoredEvents:
			return n, oldest, stored, nil
		case reason := <-sub.ClosedReason:
			return n, oldest, stored, fmt.Errorf("relay closed the page: %s", reason)
		case <-pctx.Done():
			return n, oldest, stored, fmt.Errorf("page timed out: %w", pctx.Err())
		}
	}
}
