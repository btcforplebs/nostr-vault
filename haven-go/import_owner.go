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
//     way, window by window (dropped after 3 silent windows), so no relay
//     gives fewer notes than before.
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
			log.Printf("⚠️ negentropy import %s: %d of %d listed notes didn't come; %d still missing after asking again", url, len(stats.Missing), stats.RemoteOnly, left)
			if left > 0 {
				return false
			}
		}
		log.Printf("📥 negentropy import %s: %d notes it had that the vault didn't", url, stats.RemoteOnly)
		return true
	case errors.Is(err, negsync.ErrUnsupported):
		markNegentropyUnsupported(url)
	case errors.Is(err, negsync.ErrRefused):
		slog.Warn("negentropy import refused, paging instead", "relay", url, "err", err)
		markNegentropyUnsupported(url)
		noteRelayRefusal(url, err)
	default:
		noteRelayRefusal(url, err)
		slog.Warn("negentropy import failed, paging instead", "relay", url, "err", err)
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

func importOwnerNotes(ctx context.Context) {
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
		keepMu.Lock()
		defer keepMu.Unlock()
		if !verifiedOwnerNote(ev) {
			slog.Debug("🚫 skipping a note that failed the check", "id", ev.ID)
			return false
		}
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
	var (
		mu    sync.Mutex
		total int
		redo  []string // lanes that didn't finish: re-read by window
		wg    sync.WaitGroup
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
					log.Printf("📦 Imported %d notes from %s to %s (%s, %s)", n, from, today, url, how)
				}
			}
			negStore := &importNegStore{outbox: &outboxNegStore{outbox: wdb, advance: func(nostr.Timestamp) { stored.Add(1) }}}
			synced := false
			runsafe.Run("importOwnerNotes.negentropy", func() { synced = importOwnerNegentropy(ctx, url, filter, negStore) })
			if synced || ctx.Err() != nil {
				report("negentropy")
				return
			}
			var res windowResult
			runsafe.Run("importOwnerNotes.lane", func() {
				res = fetchPaged(ctx, []string{url}, filter, importLaneMaxPages, func(ev *nostr.Event) {
					if keep(ev) {
						stored.Add(1)
					}
				})
			})
			report("paged")
			if len(res.Short) > 0 || len(res.Silent) > 0 {
				mu.Lock()
				redo = append(redo, url)
				mu.Unlock()
			}
		}(url)
	}
	wg.Wait()
	if ctx.Err() != nil {
		return
	}

	// A lane that stopped partway, or never answered, is read window by
	// window, as before.
	if len(redo) > 0 {
		log.Printf("⚠️ %d relay(s) did not finish their whole history; reading them window by window: %v", len(redo), redo)
		total += importOwnerWindows(ctx, redo, startTime, owners, func(ev *nostr.Event) bool { return keep(ev) })
	}
	if failed > 0 {
		log.Printf("⚠️ Failed to import %d notes", failed)
	}
	log.Println("✅ owner note import complete! Imported", total, "notes")
	debug.FreeOSMemory()
}

// importSilentWindows: a relay silent (nothing, no EOSE) for this many
// windows in a row is dead or refusing, not slow: it is dropped, so it costs
// a minute at most instead of every window's idle wait.
const importSilentWindows = 3

// importOwnerWindows is the old walk, 10 days at a time from start, for the
// relays whose lane didn't finish. Returns how many notes it stored.
func importOwnerWindows(ctx context.Context, relays []string, start time.Time, owners []string, keep func(*nostr.Event) bool) int {
	stored := 0
	silent := map[string]int{}
	relays = slices.Clone(relays)
	for begin := start; len(relays) > 0 && !begin.After(time.Now()); begin = begin.Add(240 * time.Hour) {
		end := begin.Add(240 * time.Hour)
		s, u := nostr.Timestamp(begin.Unix()), nostr.Timestamp(end.Unix())
		var res windowResult
		runsafe.Run("importOwnerNotes.windows", func() {
			res = fetchWindowPaged(ctx, relays, nostr.Filter{Authors: owners, Since: &s, Until: &u}, func(ev *nostr.Event) {
				if keep(ev) {
					stored++
				}
			})
		})
		if ctx.Err() != nil {
			return stored
		}
		if len(res.Short) > 0 {
			log.Printf("⚠️ %d relay(s) stopped partway through %s to %s; their older notes there may be missing: %v",
				len(res.Short), begin.Format(layout), end.Format(layout), res.Short)
		}
		for _, url := range relays {
			if slices.Contains(res.Silent, url) {
				silent[url]++
			} else {
				silent[url] = 0
			}
		}
		relays = slices.DeleteFunc(relays, func(url string) bool {
			if silent[url] >= importSilentWindows {
				log.Printf("⚠️ %s answered nothing for %d windows in a row; not asking it again", url, importSilentWindows)
				return true
			}
			return false
		})
	}
	return stored
}
