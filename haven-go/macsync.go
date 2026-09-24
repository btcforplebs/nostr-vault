package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"log/slog"
	"strings"
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
// runs 24/7. Its outbox (the base URL) is treated as a seed relay and its
// inbox (base + "/inbox") as an inbox-only relay, so the regular catch-up
// rounds cover it like any other relay. On top of that, the first time a given
// Mac URL is seen, its entire history is copied once (macBackfiller) — the
// rolling catch-up window only reaches back SyncWindowDays.

// macRelayURLs returns the Mac relay's outbox and inbox URLs, or two empty
// strings when no Mac relay is configured.
func macRelayURLs() (base, inbox string) {
	base = strings.TrimRight(strings.TrimSpace(config.MacRelayURL), "/")
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
	Posts      int    `json:"posts"`    // owner events copied
	Mentions   int    `json:"mentions"` // tagged events copied (incl. ones then rejected as spam)
	Missing    int    `json:"missing"`  // still missing after the check pass; -1 = not measurable (paged)
	Error      string `json:"error,omitempty"`
	StartedAt  int64  `json:"started_at"`
	FinishedAt int64  `json:"finished_at,omitempty"`
}

const macSyncStatusPath = "mac_sync_status.json"

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

// macBackfillSessionTimeout bounds one negentropy session (one slice).
const macBackfillSessionTimeout = 90 * time.Second

// macPageLimit is the page size for the paged fallback. Paging stops on an
// empty page, not a short one, so a relay capping below this is still walked
// to the end.
const macPageLimit = 500

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
}

// target is one side of the copy: the Mac's outbox into ours, or its inbox
// into our inbox/chat.
type macTarget struct {
	name   string // "posts" | "mentions"
	url    string
	store  nostr.RelayStore
	filter nostr.Filter // without since/until
}

func (b *macBackfiller) targets(base, inbox string) []macTarget {
	return []macTarget{
		{"posts", base, b.outboxNeg, nostr.Filter{Authors: b.pTags}},
		{"mentions", inbox, b.inboxNeg, nostr.Filter{Tags: nostr.TagMap{"p": b.pTags}}},
	}
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
// force re-runs it regardless (the app's "Check sync with Mac").
func (b *macBackfiller) runIfNeeded(ctx context.Context, force bool) {
	base, inbox := macRelayURLs()
	if base == "" {
		return
	}
	prev := loadMacSyncStatus()
	if !force && prev.MacURL == base && prev.State == "done" {
		return
	}
	st := b.run(ctx, base, inbox)
	if ctx.Err() != nil {
		return // app went away mid-copy: leave the status saying running, retry next launch
	}
	saveMacSyncStatus(st)
}

func (b *macBackfiller) run(ctx context.Context, base, inbox string) macSyncStatus {
	st := macSyncStatus{MacURL: base, State: "running", Method: "negentropy", StartedAt: b.now().Unix()}
	saveMacSyncStatus(st)
	log.Println("🖥️ copying full history from Mac relay", base)

	var errs []string
	missing := 0
	measurable := true
	for _, t := range b.targets(base, inbox) {
		copied, left, err := b.copyTarget(ctx, t)
		if ctx.Err() != nil {
			return st
		}
		switch t.name {
		case "posts":
			st.Posts = copied
		case "mentions":
			st.Mentions = copied
		}
		if left < 0 {
			measurable = false
			st.Method = "paged"
		} else {
			missing += left
		}
		if err != nil {
			errs = append(errs, t.name+": "+err.Error())
		}
	}
	// Old backlog doesn't notify (isNotifyableAge), and this isn't a return
	// from absence either: reset the batch without a summary.
	b.notifier.flush(false)

	st.FinishedAt = b.now().Unix()
	st.Missing = missing
	if !measurable {
		st.Missing = -1
	}
	switch {
	case len(errs) > 0 && st.Posts+st.Mentions == 0:
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

// macMaxCopyPasses bounds the reconcile-until-converged loop. On a real Mac
// relay one pass left a few dozen of ~26k events behind (a batch the relay
// didn't answer); the second pass picked them up.
const macMaxCopyPasses = 5

// copyTarget copies one side, repeating the reconciliation until a pass finds
// nothing it can still fix, then reports what is left: remote-only IDs the
// phone has not accounted for. left is -1 when the Mac has no NIP-77 and the
// paged fallback ran (a page walk can't tell "missing" from "rejected").
func (b *macBackfiller) copyTarget(ctx context.Context, t macTarget) (copied, left int, err error) {
	if b.negEnabled && relaySupportsNegentropy(ctx, t.url) {
		unresolved := -1
		for pass := 0; pass < macMaxCopyPasses; pass++ {
			acc := &accountingStore{RelayStore: t.store}
			remote, perr := b.reconcileAll(ctx, t, acc)
			copied += int(acc.stored.Load())
			if perr != nil {
				if pass == 0 && (errors.Is(perr, negsync.ErrUnsupported) || errors.Is(perr, negsync.ErrRefused)) {
					log.Println("ℹ️ Mac relay has no usable NIP-77, copying page by page:", t.url, perr)
					markNegentropyUnsupported(t.url)
					break
				}
				return copied, 0, perr
			}
			markNegentropySupported(t.url)
			// Unresolved: listed by the Mac, and after this pass still neither
			// stored here, deliberately rejected, nor superseded by a newer
			// version of the same replaceable event.
			unresolved = max(0, remote-int(acc.stored.Load())-int(acc.accounted.Load()))
			// Only a fresh pass that stored nothing is a real check: on a real
			// Mac relay the first pass did not even list some events that the
			// second pass then found and stored.
			if acc.stored.Load() == 0 {
				return copied, unresolved, nil
			}
		}
		if unresolved >= 0 {
			// Every pass still stored something new: not converged, so this
			// can't be reported as complete. The next launch (or a check)
			// continues where it stopped.
			return copied, unresolved, fmt.Errorf("still finding new events after %d passes", macMaxCopyPasses)
		}
	}
	n, perr := b.pageAll(ctx, t)
	return copied + n, -1, perr
}

// reconcileAll runs one Down reconciliation per time slice into store and
// returns the number of IDs the Mac had that we lacked at the start of each.
func (b *macBackfiller) reconcileAll(ctx context.Context, t macTarget, store nostr.RelayStore) (remote int, err error) {
	for _, sl := range b.slices() {
		if ctx.Err() != nil {
			return remote, ctx.Err()
		}
		f := t.filter
		f.Since, f.Until = sl[0], sl[1]
		sctx, cancel := context.WithTimeout(ctx, macBackfillSessionTimeout)
		stats, serr := negsync.Sync(sctx, store, t.url, f, negsync.Down)
		cancel()
		remote += stats.RemoteOnly
		if serr != nil {
			return remote, serr
		}
	}
	return remote, nil
}

// accountingStore wraps a sync store and classifies every event the Mac sends:
// stored (now present locally), accounted (present but not stored this time:
// already had it, deliberately rejected — the vector lists rejects as haves —
// or a replaceable version older than one we keep). Anything else stays
// missing. Publish runs concurrently from negsync's batch workers.
type accountingStore struct {
	nostr.RelayStore
	stored    atomic.Int64
	accounted atomic.Int64
}

func (s *accountingStore) Publish(ctx context.Context, ev nostr.Event) error {
	before := s.has(ctx, &ev)
	err := s.RelayStore.Publish(ctx, ev)
	switch {
	case before:
		s.accounted.Add(1)
	case s.has(ctx, &ev):
		s.stored.Add(1)
	case s.superseded(ctx, &ev):
		s.accounted.Add(1)
	}
	return err
}

// has reports whether the local vector lists ev: stored, tombstoned or a
// cached reject. Bounded to ev's own second so the stub lists stay small.
func (s *accountingStore) has(ctx context.Context, ev *nostr.Event) bool {
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

// pageAll walks the Mac relay newest to oldest with an until cursor. It stops
// on an empty page rather than a short one, so it can't mistake a relay's own
// result cap for the end of history.
func (b *macBackfiller) pageAll(ctx context.Context, t macTarget) (int, error) {
	var until *nostr.Timestamp
	copied := 0
	for ctx.Err() == nil {
		f := t.filter
		f.Limit = macPageLimit
		f.Until = until
		pctx, cancel := context.WithTimeout(ctx, macBackfillSessionTimeout)
		oldest := nostr.Timestamp(0)
		n := 0
		for ev := range pool.FetchMany(pctx, []string{t.url}, f) {
			n++
			if oldest == 0 || ev.CreatedAt < oldest {
				oldest = ev.CreatedAt
			}
			if t.name == "posts" {
				processOwnerEvent(ctx, ev, b.wdbOutbox)
			} else {
				processInboxEvent(ctx, ev, b.wdbInbox, b.wdbChat, b.notifier, b.rejects)
			}
			copied++
		}
		cancel()
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
	return copied, ctx.Err()
}
