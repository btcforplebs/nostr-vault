package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"log/slog"
	"maps"
	"runtime/debug"
	"slices"
	"sync"
	"sync/atomic"
	"time"

	"github.com/barrydeen/haven/internal/negsync"
	"github.com/barrydeen/haven/pkg/runsafe"
	"github.com/fiatjaf/eventstore"
	"github.com/nbd-wtf/go-nostr"
)

// Moving in, the owner's own notes (Logen 2026-11-04, from
// RESEARCH/NV_MOVING_IN_SPEED.md). It used to walk 10-day windows from the
// start date, every relay in lock-step, so each window waited for the slowest
// relay: a relay that answers one request every 12 s held Logen's 21,195
// notes to 29 minutes. Now:
//
//  1. Each relay runs on its own, all at once, one request in flight each:
//     a slow relay only delays its own notes.
//  2. A relay that speaks NIP-77 reconciles the whole history in one
//     negentropy session (his own relay: 21,211 notes in 4.3 s; a re-run
//     0.7 s). Notes it listed but didn't send are asked for by id; if any
//     still lack, it is paged as in 3.
//  3. Every other relay pages its whole history newest first: a sparse year
//     costs one request instead of 36.
//  4. A relay whose lane stopped partway, or never answered, is read the old
//     way, window by window (dropped after 3 silent windows; windows widen
//     while every relay answers empty), so no relay gives fewer notes than
//     before. A lane that ended with an empty EOSE has nothing older and is
//     not walked at all.
//
// Live, Logen's 8 relays (2026-11-04): 21 s instead of 29 m 24 s, every note
// the old walk found (bar 8 he had deleted); a re-run 32 s and 251 requests
// (the old walk: 1,900 every time).
//
// Nothing is ever sent to a relay: negentropy runs Down only, and every note
// kept is checked (id, signature, an owner as author) before it is stored.

// importNegTimeout: one relay's whole negentropy session. A relay that stalls
// past it is read by paging instead. Shorter in tests.
var importNegTimeout = 3 * time.Minute

// importLaneDeadline: one relay's whole-history lane. Each page ends when the
// relay goes quiet, but one that trickles a real note every few seconds keeps
// pages open for good (Tron, PR 1663); past this its lane stops and the relay
// is read window by window, where every window ends. Shorter in tests.
var importLaneDeadline = 15 * time.Minute

const (
	// importLaneMaxPages: a whole-history lane's backstop, 2M notes at 500 a
	// page; a lane that reaches it is re-read window by window.
	importLaneMaxPages = 4000
)

// importNegOpen: how long a relay may stay silent after NEG-OPEN before it
// counts as not speaking NIP-77 (the catch-up waits 15 s). A relay that does
// answers in one round trip (Logen's own, ~21k ids: 0.5 s); the wait is what
// a relay that silently ignores it costs its lane, once a day (cached).
const importNegOpen = 8 * time.Second

// importNegSync reconciles store with url for f, fetching only (Down).
// Replaced in tests.
var importNegSync = func(ctx context.Context, store nostr.RelayStore, url string, f nostr.Filter) (negsync.Stats, error) {
	return negsync.Sync(ctx, store, url, f, negsync.Down, negsync.WithOpenTimeout(importNegOpen))
}

// importNegSupported: relaySupportsNegentropy, replaced in tests.
var importNegSupported = relaySupportsNegentropy

// verifiedOwnerNote: the note is what it claims to be (its id is the hash of
// its content, and the owner signed it) and an owner wrote it. go-nostr
// checks the signature but trusts the claimed id, so a relay could otherwise
// file a real note under a made-up id.
func verifiedOwnerNote(ev *nostr.Event) bool {
	if ev == nil {
		return false
	}
	if _, ok := config.WhitelistedPubKeys[ev.PubKey]; !ok {
		return false
	}
	if !ev.CheckID() {
		return false
	}
	ok, _ := ev.CheckSignature()
	return ok
}

// importNegStore is the outbox seen by an import negentropy session: the
// catch-up's owner adapter (deletions, duplicates, blacklist), behind the
// note check.
type importNegStore struct {
	outbox *outboxNegStore
	// lock: the import's one store lock, shared with the paged lanes' keep.
	// The deletion check and the store must be one step: a kind 5 arriving
	// on one lane while its target arrives on another could otherwise both
	// pass the check, leaving the note beside its own deletion (Tron, PR 1663).
	lock *sync.Mutex
}

func (s *importNegStore) QuerySync(ctx context.Context, f nostr.Filter) ([]*nostr.Event, error) {
	return s.outbox.QuerySync(ctx, f)
}

// QueryEvents is the upload source, and an import never uploads: nothing.
func (s *importNegStore) QueryEvents(ctx context.Context, f nostr.Filter) (chan *nostr.Event, error) {
	ch := make(chan *nostr.Event)
	close(ch)
	return ch, nil
}

func (s *importNegStore) Publish(ctx context.Context, ev nostr.Event) error {
	if !verifiedOwnerNote(&ev) {
		return fmt.Errorf("not a verified owner note: %s", ev.ID)
	}
	if s.lock != nil {
		s.lock.Lock()
		defer s.lock.Unlock()
	}
	// A lane may store the same note a moment earlier: that is no failure.
	if err := s.outbox.Publish(ctx, ev); err != nil && !errors.Is(err, eventstore.ErrDupEvent) {
		return err
	}
	return nil
}

// importOwnerNegentropy reconciles filter with url, if it may speak NIP-77,
// and reports whether it handed over every note it listed: such a relay
// needs no paging. Unsupported answers are cached as the catch-up caches them.
func importOwnerNegentropy(ctx context.Context, url string, filter nostr.Filter, store *importNegStore) bool {
	if relayBanned(url) || !importNegSupported(ctx, url) {
		return false
	}
	rctx, cancel := context.WithTimeout(ctx, importNegTimeout)
	defer cancel()
	stats, err := importNegSync(rctx, store, url, filter)
	switch {
	case err == nil:
		markNegentropySupported(url)
		if len(stats.Missing) > 0 {
			// Listed notes it didn't send (or that failed the check): ask
			// for exactly those once more, then page it if any still lack.
			left := importFetchIDs(ctx, url, stats.Missing, store)
			log.Printf("⚠️ negentropy import %s: %d of %d listed notes didn't come; %d still missing after asking again", seedHost(url), len(stats.Missing), stats.RemoteOnly, left)
			if left > 0 {
				return false
			}
		}
		log.Printf("📥 negentropy import %s: %d notes it had that the vault didn't", seedHost(url), stats.RemoteOnly)
		return true
	case errors.Is(err, negsync.ErrUnsupported):
		markNegentropyUnsupported(url)
	case errors.Is(err, negsync.ErrRefused):
		slog.Warn("negentropy import refused, paging instead", "relay", seedHost(url), "err", withoutSeedPath(err.Error(), url))
		markNegentropyUnsupported(url)
		noteRelayRefusal(url, err)
	default:
		noteRelayRefusal(url, err)
		slog.Warn("negentropy import failed, paging instead", "relay", seedHost(url), "err", withoutSeedPath(err.Error(), url))
	}
	return false
}

// importFetchIDs asks url for exactly ids (a page at a time) and stores what
// comes; returns how many it still didn't get.
func importFetchIDs(ctx context.Context, url string, ids []string, store *importNegStore) int {
	left := 0
	for start := 0; start < len(ids); start += importPageLimit {
		batch := ids[start:min(start+importPageLimit, len(ids))]
		evs, _ := importPage(ctx, url, nostr.Filter{IDs: batch, Limit: len(batch)})
		got := map[string]bool{}
		for _, ev := range evs {
			if ev != nil && slices.Contains(batch, ev.ID) && store.Publish(ctx, *ev) == nil {
				got[ev.ID] = true
			}
		}
		left += len(batch) - len(got)
	}
	return left
}

// importWriteKey marks a context whose outbox writes are Moving in's.
type importWriteKey struct{}

// isImportWrite: ctx carries Moving in's owner-note writes. The outbox's list
// history (list_history.go keep) files an owner list arriving this way as an
// imported version, not into the vault's own history: an old version a seed
// relay still serves used to land among the vault's own and could trim it,
// the erosion 5f00485d9 fixed only for the history scan (Tidy import audit,
// item 11).
func isImportWrite(ctx context.Context) bool {
	v, _ := ctx.Value(importWriteKey{}).(bool)
	return v
}

func importOwnerNotes(ctx context.Context) {
	ctx = context.WithValue(ctx, importWriteKey{}, true)
	startTime, err := time.Parse(layout, config.ImportStartDate)
	if err != nil {
		fmt.Println("Error parsing start date:", err)
		return
	}
	wdb := eventstore.RelayWrapper{Store: outboxDB}
	since := nostr.Timestamp(startTime.Unix())
	owners := slices.Collect(maps.Keys(config.WhitelistedPubKeys))
	filter := nostr.Filter{Authors: owners, Since: &since}
	from, today := startTime.Format(layout), time.Now().Format(layout)

	// keep stores one note from a page, one at a time across every relay:
	// true when it is new to the vault.
	var keepMu sync.Mutex
	failed := 0
	keep := func(ev *nostr.Event) bool {
		if !verifiedOwnerNote(ev) {
			slog.Debug("🚫 skipping a note that failed the check", "id", ev.ID)
			return false
		}
		keepMu.Lock()
		defer keepMu.Unlock()
		if isBlacklisted(ev.PubKey) {
			slog.Debug("🚫 skipping event from blacklisted pubkey", "pubkey", ev.PubKey, "id", ev.ID)
			return false
		}
		if isDuplicate(ctx, wdb, ev) {
			return false // another relay's lane or negentropy got it first
		}
		if isDeleted(ctx, outboxDB, ev) {
			slog.Debug("🚫 skipping deleted event", "id", ev.ID)
			return false
		}
		applyImportedDeletion(ctx, outboxDB, ev)
		if err := wdb.Publish(ctx, *ev); err != nil {
			if errors.Is(err, eventstore.ErrDupEvent) {
				return false
			}
			log.Println("🚫  error importing note", ev.ID, ":", err)
			failed++
			return false
		}
		return true
	}

	// Each relay on its own: negentropy if it may speak it, else (or if it
	// didn't hand everything over) its whole history paged newest first.
	// A slow relay, a silent probe or a long lane only delays its own notes.
	// The refusal-retry budget was started by runImport, before WoT init and
	// the list-history scan dialed these same relays.
	var (
		mu    sync.Mutex
		total int
		redo  []walkRelay // lanes that didn't finish: re-read by window, from where they stopped
		// negEmpty: relays whose negentropy finished but stored nothing.
		// Checked once the lanes are done (importNegEmptyHolds).
		negEmpty []string
		wg       sync.WaitGroup
	)
	for _, url := range importRelays() {
		wg.Add(1)
		go func(url string) {
			defer wg.Done()
			var stored atomic.Int64
			report := func(how string) {
				n := int(stored.Load())
				mu.Lock()
				total += n
				mu.Unlock()
				if n > 0 {
					log.Printf("📦 Imported %d notes from %s to %s (%s, %s)", n, from, today, seedHost(url), how)
				}
			}
			negStore := &importNegStore{outbox: &outboxNegStore{outbox: wdb, advance: func(nostr.Timestamp) { stored.Add(1) }}, lock: &keepMu}
			synced := false
			runsafe.Run("importOwnerNotes.negentropy", func() { synced = importOwnerNegentropy(ctx, url, filter, negStore) })
			if synced || ctx.Err() != nil {
				report("negentropy")
				if synced && stored.Load() == 0 {
					mu.Lock()
					negEmpty = append(negEmpty, url)
					mu.Unlock()
				}
				return
			}
			// A refusal on the negentropy socket bans the relay for every
			// dial after it: its one retry comes before the lane, not never.
			if relayBanned(url) {
				importRetryAfterRefusal(ctx, url)
			}
			lane := func() (windowResult, bool) {
				var res windowResult
				lctx, cancel := context.WithTimeout(ctx, importLaneDeadline)
				defer cancel()
				runsafe.Run("importOwnerNotes.lane", func() {
					res = fetchPaged(lctx, []string{url}, filter, importLaneMaxPages, func(ev *nostr.Event) {
						if keep(ev) {
							stored.Add(1)
						}
					})
				})
				return res, lctx.Err() != nil && ctx.Err() == nil
			}
			res, overran := lane()
			if len(res.Silent) > 0 && relayBanned(url) && importRetryAfterRefusal(ctx, url) {
				res, overran = lane() // refused partway in: asked once more after a pause
			}
			report("paged")
			if overran {
				log.Printf("⚠️ %s still sending after %s; reading it window by window", seedHost(url), importLaneDeadline)
			}
			if len(res.Empty) > 0 {
				log.Printf("⚠️ %s answered the whole-history ask with nothing; checking it window by window", seedHost(url))
			}
			// An empty first answer is unconfirmed, not "nothing": some
			// relays answer a wide scan empty but 10 days in full (Tidy,
			// RESEARCH/NV_IMPORT_BEFORE_NEGENTROPY_2026_11_05.md fix 1). The
			// walk widens over empty windows, so one that really has
			// nothing costs about a dozen asks.
			if overran || len(res.Short) > 0 || len(res.Silent) > 0 || len(res.Empty) > 0 {
				// The lane read newest first down to its oldest note: only
				// what is older is left. Starting the walk there (not at the
				// start date) means a walk cut by its deadline leaves the
				// oldest stretch unread, never a gap in the middle.
				w := walkRelay{url: url, top: time.Now(), alive: res.Sent[url] > 0}
				if o, ok := res.Oldest[url]; ok {
					w.top = time.Unix(int64(o)+1, 0)
				}
				mu.Lock()
				redo = append(redo, w)
				mu.Unlock()
			}
		}(url)
	}
	wg.Wait()
	if ctx.Err() != nil {
		return
	}

	// A negentropy session that stored nothing while other relays' lanes
	// found notes the vault lacked may have been answered with an empty
	// list it shouldn't have (fix 2): one limit:1 ask decides it, and a
	// relay that does hold an owner note is walked like a lane that stopped.
	if total > 0 {
		for _, url := range importNegEmptyHolds(ctx, negEmpty, filter) {
			log.Printf("⚠️ %s: negentropy brought nothing new but it holds notes; reading it window by window", seedHost(url))
			redo = append(redo, walkRelay{url: url, top: time.Now(), alive: true})
		}
		if ctx.Err() != nil {
			return
		}
	}

	// A lane that stopped partway, or never answered, is read window by
	// window, from where it stopped down to the start date.
	if len(redo) > 0 {
		names := make([]string, len(redo))
		for i, w := range redo {
			names[i] = seedHost(w.url)
		}
		log.Printf("⚠️ %d relay(s) did not finish their whole history; reading them window by window: %v", len(redo), names)
		total += importOwnerWindows(ctx, redo, startTime, owners, func(ev *nostr.Event) bool { return keep(ev) })
	}
	if failed > 0 {
		log.Printf("⚠️ Failed to import %d notes", failed)
	}
	log.Println("✅ owner note import complete! Imported", total, "notes")
	debug.FreeOSMemory()
}

// importNegEmptyHolds: of urls, the relays that answer a limit:1 ask over
// filter with a real owner note. All asked at once; each costs one request.
func importNegEmptyHolds(ctx context.Context, urls []string, filter nostr.Filter) []string {
	var (
		mu    sync.Mutex
		holds []string
		wg    sync.WaitGroup
	)
	for _, url := range urls {
		wg.Add(1)
		go func(url string) {
			defer wg.Done()
			f := filter
			f.Limit = 1
			var evs []*nostr.Event
			runsafe.Run("importOwnerNotes.negEmpty", func() { evs, _ = importPage(ctx, url, f) })
			for _, ev := range evs {
				if filter.Matches(ev) && verifiedOwnerNote(ev) {
					mu.Lock()
					holds = append(holds, url)
					mu.Unlock()
					return
				}
			}
		}(url)
	}
	wg.Wait()
	slices.Sort(holds)
	return holds
}

// unreadSpan: the stretch of history the walk left unread from some relay
// (deadline or drop), reported in IMPORT_RESULT as reason
// unread:<from>..<to> so an app can offer "Run again" over just that range.
// One span: the union, so a re-run over it covers every gap.
type unreadSpan struct{ from, to time.Time }

func (u *unreadSpan) add(from, to time.Time) {
	if !to.After(from) {
		return
	}
	if u.from.IsZero() || from.Before(u.from) {
		u.from = from
	}
	if to.After(u.to) {
		u.to = to
	}
}

// reason: "unread:2021-01-01..2024-03-10", or "" if nothing was left.
func (u *unreadSpan) reason() string {
	if u.from.IsZero() {
		return ""
	}
	return "unread:" + u.from.Format(layout) + ".." + u.to.Format(layout)
}

// report adds the span to the import being collected, if any.
func (u *unreadSpan) report() {
	if r := u.reason(); r != "" {
		if o := currentImport.Load(); o != nil {
			o.cut(r)
		}
	}
}

// importSilentWindows: a relay that has sent no note in this import and is
// silent (nothing, no EOSE) for this many windows in a row is dropped: each
// such window costs an idle wait, and ~140 of them held a fresh import with no
// sign of life for ~45 min (nostr-pub.wellorder.net, 12 mini, 2026-11-04).
const importSilentWindows = 3

// importAliveSilentWindows: the same for a relay that HAS sent notes. One that
// never ends an answer with EOSE (it goes quiet instead) looks silent in every
// window it has nothing for; it used to be dropped after 3 such windows with
// the rest of its history unread (Tidy import audit, item 1). Now it is only
// dropped after this many in a row, which (windows widening) is years.
const importAliveSilentWindows = 10

// importQuietIdle: the idle wait for a relay that has sent notes but never
// sends EOSE. Its notes come at once; the wait is only how long its silence
// takes to read as "that's all". Shorter in tests.
var importQuietIdle = 5 * time.Second

// importWalkDeadline: the most the whole window walk may take, however many
// relays and windows are left. Past it the walk stops with what it has.
// Shorter in tests.
var importWalkDeadline = 15 * time.Minute

// importWindowStride: the walk's base window, 10 days.
const importWindowStride = 240 * time.Hour

// importMaxStride: the widest window the walk grows to, 160 days. A run of
// windows every relay answers empty doubles the next one, so a relay with
// nothing older (nostr-pub.wellorder.net, 12 mini, 2026-11-05) costs a dozen
// asks for four years instead of ~140.
const importMaxStride = 16 * importWindowStride

// walkRelay: one relay for the window walk. top: where its lane stopped (its
// oldest note, or now if it sent none); only what is older is read. alive: it
// has sent notes in this import.
type walkRelay struct {
	url   string
	top   time.Time
	alive bool
}

// walkState: one relay's standing in the walk.
type walkState struct {
	walkRelay
	silent  int  // windows in a row with no answer and no note
	noEOSE  bool // it sent notes and then went quiet instead of EOSE
	dropped bool
}

// importOwnerWindows reads, window by window, what the relays' lanes didn't:
// from the newest place a lane stopped down to start, newest first, so a walk
// cut by its deadline leaves only the oldest stretch unread (and logs it). A
// relay is asked only for windows below where its own lane stopped. Windows
// are 10 days, wider while every relay answers empty. Each window logs one
// line ("Imported N notes from X to Y" or "No notes found for X to Y") that
// the apps' import screens read. Returns how many notes it stored.
func importOwnerWindows(ctx context.Context, relays []walkRelay, start time.Time, owners []string, keep func(*nostr.Event) bool) int {
	stored := 0
	now := time.Now()
	var unread unreadSpan
	defer unread.report()
	states := make([]*walkState, 0, len(relays))
	end := start
	for _, r := range relays {
		if r.top.After(now) {
			r.top = now
		}
		states = append(states, &walkState{walkRelay: r})
		if r.top.After(end) {
			end = r.top
		}
	}
	parent := ctx
	ctx, cancel := context.WithTimeout(ctx, importWalkDeadline)
	defer cancel()
	stride, maxStride := importWindowStride, importMaxStride
	for end.After(start) {
		begin := end.Add(-stride)
		if begin.Before(start) {
			begin = start
		}
		var asked []*walkState
		next := start // the highest top among relays not reached yet
		for _, st := range states {
			if st.dropped {
				continue
			}
			if st.top.After(begin) {
				asked = append(asked, st)
			} else if st.top.After(next) {
				next = st.top
			}
		}
		if len(asked) == 0 {
			if !next.After(start) {
				break // every relay dropped, or nothing left below its lane
			}
			end = next // nothing to read down to the next relay's lane
			continue
		}
		urls := make([]string, len(asked))
		idle := map[string]time.Duration{}
		for i, st := range asked {
			urls[i] = st.url
			if st.alive && st.noEOSE {
				idle[st.url] = importQuietIdle
			}
		}
		s, u := nostr.Timestamp(begin.Unix()), nostr.Timestamp(end.Unix())
		before := stored
		var res windowResult
		runsafe.Run("importOwnerNotes.windows", func() {
			res = fetchWindowPaged(withPageIdle(ctx, idle), urls, nostr.Filter{Authors: owners, Since: &s, Until: &u}, func(ev *nostr.Event) {
				if keep(ev) {
					stored++
				}
			})
		})
		if ctx.Err() != nil {
			if parent.Err() == nil {
				log.Printf("⚠️ reading %v window by window passed %s with %d notes; not read: %s to %s", urls, importWalkDeadline, stored, start.Format(layout), end.Format(layout))
				unread.add(start, end)
			}
			return stored
		}

		// No answer and no note: a relay that refused us during this import
		// gets its one retry (the same window again); otherwise it counts.
		noAnswer := func(st *walkState) bool {
			return res.Sent[st.url] == 0 && (slices.Contains(res.Silent, st.url) || slices.Contains(res.Quiet, st.url))
		}
		// All of them at once: one pause for every relay that refused, not
		// one 35 s pause after another.
		var (
			retryMu sync.Mutex
			retry   bool
			retries sync.WaitGroup
		)
		for _, st := range asked {
			if !noAnswer(st) || !relayBanned(st.url) {
				continue
			}
			retries.Add(1)
			go func(url string) {
				defer retries.Done()
				if importRetryAfterRefusal(ctx, url) {
					retryMu.Lock()
					retry = true
					retryMu.Unlock()
				}
			}(st.url)
		}
		retries.Wait()
		if ctx.Err() != nil {
			return stored
		}
		if retry {
			continue
		}
		// Silence from a relay that never sent a note is a failure (it
		// stops the window widening); from one that has, it is its way of
		// saying "nothing here".
		failed := len(res.Short) > 0
		for _, st := range asked {
			if noAnswer(st) && !st.alive {
				failed = true
			}
		}
		if failed && stride > importWindowStride {
			// A relay that answers 10 days may time out on a wider range:
			// read this stretch again 10 days at a time, and never widen
			// this far again. Nothing is counted against it for the wide ask.
			maxStride, stride = stride/2, importWindowStride
			continue
		}
		shown := end
		if shown.After(now) {
			shown = now
		}
		if n := stored - before; n > 0 {
			log.Printf("📦 Imported %d notes from %s to %s (window by window)", n, begin.Format(layout), shown.Format(layout))
		} else {
			log.Printf("ℹ️ No notes found for %s to %s", begin.Format(layout), shown.Format(layout))
		}
		if len(res.Short) > 0 {
			log.Printf("⚠️ %d relay(s) stopped partway through %s to %s; their older notes there may be missing: %v",
				len(res.Short), begin.Format(layout), end.Format(layout), res.Short)
		}
		for _, st := range asked {
			switch {
			case res.Sent[st.url] > 0:
				st.alive, st.silent = true, 0
				if slices.Contains(res.Quiet, st.url) {
					st.noEOSE = true
				}
			case noAnswer(st):
				st.silent++
			default:
				st.silent = 0 // an empty answer, with EOSE
			}
			limit := importSilentWindows
			if st.alive {
				limit = importAliveSilentWindows
			}
			if st.silent >= limit {
				st.dropped = true
				// Alive: read down to this window. Never answered: none of
				// it was read, from where its lane stopped.
				if st.alive {
					unread.add(start, begin)
					log.Printf("⚠️ %s sent notes, then nothing for %d windows in a row; not asking it again (before %s not read from it)", seedHost(st.url), limit, begin.Format(layout))
				} else {
					unread.add(start, st.top)
					log.Printf("⚠️ %s answered nothing, or went quiet without finishing, for %d windows in a row; not asking it again", seedHost(st.url), limit)
				}
			}
		}
		end = begin
		if res.Notes == 0 && !failed {
			stride = min(stride*2, maxStride)
		} else {
			stride = importWindowStride
		}
	}
	return stored
}
