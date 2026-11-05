package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/barrydeen/haven/internal/negsync"
	"github.com/fiatjaf/eventstore"
	"github.com/nbd-wtf/go-nostr"
)

// Moving in's owner notes (import_owner.go): negentropy where a relay speaks
// it, whole-history lanes elsewhere, windows only for a lane that stopped short.

// moveInSetup: an owner, an empty outbox, the start date `days` ago, the
// given seed relays, and a private capability cache.
func moveInSetup(t *testing.T, days int, relays ...string) (testKey, DBBackend) {
	t.Helper()
	owner := newTestKey(t)
	savedCfg, savedDB, savedPool, savedReach := config, outboxDB, pool, reachableImportRelays.Load()
	savedCaps := negCapsFile
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(func() {
		cancel()
		config, outboxDB, pool, negCapsFile = savedCfg, savedDB, savedPool, savedCaps
		reachableImportRelays.Store(savedReach)
		resetNegCaps()
	})
	negCapsFile = filepath.Join(t.TempDir(), "negentropy_caps.json")
	resetNegCaps()
	setupSyncConfig(owner.pk)
	config.OwnerPubKey = owner.pk
	config.ImportStartDate = time.Now().AddDate(0, 0, -days).Format(layout)
	config.ImportSeedRelays = relays
	reachableImportRelays.Store(nil)
	pool = nostr.NewSimplePool(ctx)
	db := newTestBackend(t, "outbox")
	if err := db.Init(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	outboxDB = db
	return owner, db
}

// spread: n of k's notes, one every `step` going back from now.
func spread(t *testing.T, k testKey, n int, step time.Duration) []*nostr.Event {
	t.Helper()
	now := time.Now()
	out := make([]*nostr.Event, n)
	for i := range out {
		ev := k.sign(t, nostr.Event{Kind: nostr.KindTextNote, CreatedAt: nostr.Timestamp(now.Add(-time.Duration(i) * step).Unix()), Content: "note"})
		out[i] = &ev
	}
	return out
}

func count(t *testing.T, db DBBackend, pk string) int {
	t.Helper()
	ch, err := db.QueryEvents(eventstore.SetNegentropy(context.Background()), nostr.Filter{Authors: []string{pk}})
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for range ch {
		n++
	}
	return n
}

func noNegentropy(t *testing.T) {
	prev := importNegSupported
	importNegSupported = func(context.Context, string) bool { return false }
	t.Cleanup(func() { importNegSupported = prev })
}

// Two real relays: one speaks NIP-77, one doesn't and caps every answer at
// 300. The vault ends with every note either holds, and neither relay is sent
// a single event.
func TestMoveInNegentropyPlusPagedLaneGetsEverything(t *testing.T) {
	skipWithoutSockets(t)
	neg := newFakeMac(t, true, 0)
	capped := newFakeMac(t, false, 300)
	owner, db := moveInSetup(t, 800, neg.url, capped.url)
	ctx := context.Background()
	all := spread(t, owner, 1500, 12*time.Hour) // ~750 days
	want := map[string]bool{}
	for i, ev := range all {
		want[ev.ID] = true
		if i%30 != 0 { // 1450 on the negentropy relay
			if err := neg.store.Store.SaveEvent(ctx, ev); err != nil {
				t.Fatal(err)
			}
		}
		if i%3 == 0 { // 500 on the capped one, 50 of them only there
			if err := capped.store.Store.SaveEvent(ctx, ev); err != nil {
				t.Fatal(err)
			}
		}
	}

	importOwnerNotes(ctx)

	if got := count(t, db, owner.pk); got != len(want) {
		t.Fatalf("vault has %d of the owner's notes, want %d", got, len(want))
	}
	for name, relay := range map[string]*fakeMac{"negentropy": neg, "capped": capped} {
		if n := count(t, relay.store.Store.(DBBackend), owner.pk); n != map[string]int{"negentropy": 1450, "capped": 500}[name] {
			t.Fatalf("%s relay now holds %d notes: the import sent it something", name, n)
		}
	}
}

// Negentropy alone, with the relay holding everything: the lane never runs
// for it.
func TestMoveInNegentropyRelayIsNotPagedAgain(t *testing.T) {
	_, _ = moveInSetup(t, 30, "wss://neg.example")
	asked := 0
	withPagingRelaysCounting(t, &asked)
	prevSync, prevSup := importNegSync, importNegSupported
	importNegSupported = func(context.Context, string) bool { return true }
	importNegSync = func(context.Context, nostr.RelayStore, string, nostr.Filter) (negsync.Stats, error) {
		return negsync.Stats{RemoteOnly: 5, Downloaded: 5}, nil
	}
	t.Cleanup(func() { importNegSync, importNegSupported = prevSync, prevSup })

	importOwnerNotes(context.Background())

	if asked != 0 {
		t.Fatalf("a relay that handed over everything was paged %d times", asked)
	}
}

// A relay that lists notes it then doesn't send (or sends ones failing the
// check): those are asked for by id, and if they still don't come the relay
// is paged as well. Counts can't tell: here it sends as many as it listed.
func TestMoveInShortNegentropyHandoverIsAskedAgainThenPaged(t *testing.T) {
	_, _ = moveInSetup(t, 30, "wss://neg.example")
	var mu sync.Mutex
	byID, paged := 0, 0
	prev := importPage
	importPage = func(_ context.Context, _ string, f nostr.Filter) ([]*nostr.Event, bool) {
		mu.Lock()
		defer mu.Unlock()
		if len(f.IDs) > 0 {
			byID++
		} else {
			paged++
		}
		return nil, true
	}
	t.Cleanup(func() { importPage = prev })
	prevSync, prevSup := importNegSync, importNegSupported
	importNegSupported = func(context.Context, string) bool { return true }
	importNegSync = func(context.Context, nostr.RelayStore, string, nostr.Filter) (negsync.Stats, error) {
		return negsync.Stats{RemoteOnly: 5, Downloaded: 5, Missing: []string{hexid('c')}}, nil
	}
	t.Cleanup(func() { importNegSync, importNegSupported = prevSync, prevSup })

	importOwnerNotes(context.Background())

	if byID != 1 {
		t.Fatalf("the missing note was asked for by id %d times, want 1", byID)
	}
	if paged == 0 {
		t.Fatal("a note still missing after asking again: the relay was never paged")
	}
}

// When asking again by id brings the note, the relay needs no paging.
func TestMoveInMissingNoteFetchedByIDNeedsNoPaging(t *testing.T) {
	owner, db := moveInSetup(t, 30, "wss://neg.example")
	note := owner.sign(t, nostr.Event{Kind: nostr.KindTextNote, Content: "came second time"})
	var mu sync.Mutex
	paged := 0
	prev := importPage
	importPage = func(_ context.Context, _ string, f nostr.Filter) ([]*nostr.Event, bool) {
		mu.Lock()
		defer mu.Unlock()
		if len(f.IDs) > 0 {
			return []*nostr.Event{&note}, true
		}
		paged++
		return nil, true
	}
	t.Cleanup(func() { importPage = prev })
	prevSync, prevSup := importNegSync, importNegSupported
	importNegSupported = func(context.Context, string) bool { return true }
	importNegSync = func(context.Context, nostr.RelayStore, string, nostr.Filter) (negsync.Stats, error) {
		return negsync.Stats{RemoteOnly: 1, Downloaded: 1, Missing: []string{note.ID}}, nil
	}
	t.Cleanup(func() { importNegSync, importNegSupported = prevSync, prevSup })

	importOwnerNotes(context.Background())

	if !stored(t, db, note.ID) {
		t.Fatal("the note asked for by id was not stored")
	}
	if paged != 0 {
		t.Fatalf("paged %d times after the by-id ask brought everything", paged)
	}
}

// A relay that stalls its negentropy session can't hold the import: it times
// out and is paged instead.
func TestMoveInStalledNegentropyRelayCannotHangTheImport(t *testing.T) {
	_, _ = moveInSetup(t, 30, "wss://stall.example")
	asked := 0
	withPagingRelaysCounting(t, &asked)
	prevSync, prevSup, prevTimeout := importNegSync, importNegSupported, importNegTimeout
	importNegSupported = func(context.Context, string) bool { return true }
	importNegTimeout = 200 * time.Millisecond
	importNegSync = func(ctx context.Context, _ nostr.RelayStore, _ string, _ nostr.Filter) (negsync.Stats, error) {
		<-ctx.Done()
		return negsync.Stats{}, ctx.Err()
	}
	t.Cleanup(func() { importNegSync, importNegSupported, importNegTimeout = prevSync, prevSup, prevTimeout })

	done := make(chan struct{})
	go func() { importOwnerNotes(context.Background()); close(done) }()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("a stalled negentropy relay held the import")
	}
	if asked == 0 {
		t.Fatal("the stalled relay was never paged instead")
	}
}

// withPagingRelaysCounting answers every page with nothing and counts asks.
func withPagingRelaysCounting(t *testing.T, asked *int) {
	t.Helper()
	var mu sync.Mutex
	prev := importPage
	importPage = func(context.Context, string, nostr.Filter) ([]*nostr.Event, bool) {
		mu.Lock()
		*asked++
		mu.Unlock()
		return nil, true
	}
	t.Cleanup(func() { importPage = prev })
}

// A sparse two years costs a relay a few requests, not one per 10 days, and
// a slow relay doesn't hold a fast one's notes back.
func TestMoveInLanesPageWholeHistoryNotWindows(t *testing.T) {
	noNegentropy(t)
	owner, db := moveInSetup(t, 730, "wss://fast.example", "wss://slow.example")
	notes := spread(t, owner, 700, 24*time.Hour)
	fast := &pagingRelay{held: notes}
	slow := &pagingRelay{held: notes[:100]}
	relays := map[string]*pagingRelay{"wss://fast.example": fast, "wss://slow.example": slow}
	var mu sync.Mutex
	prev := importPage
	importPage = func(_ context.Context, url string, f nostr.Filter) ([]*nostr.Event, bool) {
		if url == "wss://slow.example" {
			time.Sleep(300 * time.Millisecond)
		}
		mu.Lock()
		defer mu.Unlock()
		return relays[url].answer(f)
	}
	t.Cleanup(func() { importPage = prev })

	importOwnerNotes(context.Background())

	if got := count(t, db, owner.pk); got != 700 {
		t.Fatalf("vault has %d notes, want 700", got)
	}
	// 700 notes at 500 a page: 2 pages and the empty one that ends the lane
	// (a same-second step at most adds one). 73 windows used to mean 73+.
	if fast.asks > 4 || slow.asks > 3 {
		t.Fatalf("lanes asked fast %d, slow %d times: still walking windows?", fast.asks, slow.asks)
	}
}

// A relay that times out on a whole-history scan, but answers 10 days at a
// time, still hands over everything: its lane is silent, so it is re-read by
// window.
func TestMoveInSilentLaneFallsBackToWindows(t *testing.T) {
	noNegentropy(t)
	owner, db := moveInSetup(t, 100, "wss://narrow.example")
	notes := spread(t, owner, 1200, time.Hour) // 50 days
	r := &pagingRelay{held: notes}
	var mu sync.Mutex
	prev := importPage
	importPage = func(_ context.Context, _ string, f nostr.Filter) ([]*nostr.Event, bool) {
		if f.Until == nil || f.Since == nil || *f.Until-*f.Since > 30*24*3600 {
			return nil, false // too wide: times out
		}
		mu.Lock()
		defer mu.Unlock()
		return r.answer(f)
	}
	t.Cleanup(func() { importPage = prev })

	importOwnerNotes(context.Background())

	if got := count(t, db, owner.pk); got != 1200 {
		t.Fatalf("vault has %d of 1200 notes: the silent lane was not re-read by window", got)
	}
}

// A lane that stops partway (answers, then goes quiet) is re-read by window.
func TestMoveInShortLaneFallsBackToWindows(t *testing.T) {
	noNegentropy(t)
	owner, db := moveInSetup(t, 100, "wss://tired.example")
	notes := spread(t, owner, 1200, time.Hour)
	r := &pagingRelay{held: notes}
	var mu sync.Mutex
	lanePages := 0
	prev := importPage
	importPage = func(_ context.Context, _ string, f nostr.Filter) ([]*nostr.Event, bool) {
		mu.Lock()
		defer mu.Unlock()
		if f.Since != nil && (f.Until == nil || *f.Until-*f.Since > 30*24*3600) {
			lanePages++
			if lanePages > 1 {
				return nil, false // the lane's second page never comes
			}
		}
		return r.answer(f)
	}
	t.Cleanup(func() { importPage = prev })

	importOwnerNotes(context.Background())

	if got := count(t, db, owner.pk); got != 1200 {
		t.Fatalf("vault has %d of 1200 notes: the short lane was not re-read by window", got)
	}
}

// A dead relay can't hold the import: silent in its lane, then dropped after
// importSilentWindows silent windows instead of being asked for every one.
func TestMoveInDeadRelayIsDroppedAfterAFewWindows(t *testing.T) {
	noNegentropy(t)
	_, _ = moveInSetup(t, 730, "wss://dead.example")
	asked := 0
	prev := importPage
	importPage = func(context.Context, string, nostr.Filter) ([]*nostr.Event, bool) {
		asked++
		return nil, false
	}
	t.Cleanup(func() { importPage = prev })

	importOwnerNotes(context.Background())

	if asked != 1+importSilentWindows {
		t.Fatalf("a dead relay was asked %d times, want the lane's 1 + %d windows", asked, importSilentWindows)
	}
}

// A note whose id isn't the hash of its content, or whose signature fails, or
// that someone else wrote, is never stored, from a lane or from negentropy.
func TestMoveInKeepsOnlyVerifiedOwnerNotes(t *testing.T) {
	noNegentropy(t)
	owner, db := moveInSetup(t, 10, "wss://liar.example")
	stranger := newTestKey(t)
	good := owner.sign(t, nostr.Event{Kind: nostr.KindTextNote, Content: "real"})
	forgedID := owner.sign(t, nostr.Event{Kind: nostr.KindTextNote, Content: "real too"})
	forgedID.ID = hexid('a')
	badSig := owner.sign(t, nostr.Event{Kind: nostr.KindTextNote, Content: "tampered"})
	badSig.Content = "tampered after signing"
	badSig.ID = badSig.GetID()
	notMine := stranger.sign(t, nostr.Event{Kind: nostr.KindTextNote, Content: "someone else"})
	for _, ev := range []nostr.Event{good, forgedID, badSig, notMine} {
		if verifiedOwnerNote(&ev) != (ev.ID == good.ID) {
			t.Fatalf("verifiedOwnerNote(%q) = %v", ev.Content, !(ev.ID == good.ID))
		}
	}
	prev := importPage
	importPage = func(context.Context, string, nostr.Filter) ([]*nostr.Event, bool) {
		return []*nostr.Event{&good, &forgedID, &badSig}, true
	}
	t.Cleanup(func() { importPage = prev })

	importOwnerNotes(context.Background())

	if !stored(t, db, good.ID) {
		t.Fatal("positive control: the real note was not stored")
	}
	for _, id := range []string{forgedID.ID, badSig.ID} {
		if stored(t, db, id) {
			t.Fatalf("stored %s, which failed the check", id)
		}
	}
	// Negentropy's store side refuses them too, and has nothing to upload.
	s := &importNegStore{outbox: &outboxNegStore{outbox: eventstore.RelayWrapper{Store: db}}}
	for _, ev := range []nostr.Event{forgedID, badSig, notMine} {
		if s.Publish(context.Background(), ev) == nil {
			t.Fatalf("negentropy store took %q", ev.Content)
		}
	}
	ch, _ := s.QueryEvents(context.Background(), nostr.Filter{})
	for range ch {
		t.Fatal("the import's negentropy store offered something to upload")
	}
}

// oneRefusedStore takes every event but one.
type oneRefusedStore struct {
	refuse string
	mu     sync.Mutex
	got    map[string]bool
}

func (s *oneRefusedStore) QuerySync(context.Context, nostr.Filter) ([]*nostr.Event, error) {
	return nil, nil
}

func (s *oneRefusedStore) QueryEvents(context.Context, nostr.Filter) (chan *nostr.Event, error) {
	ch := make(chan *nostr.Event)
	close(ch)
	return ch, nil
}

func (s *oneRefusedStore) Publish(_ context.Context, ev nostr.Event) error {
	if ev.ID == s.refuse {
		return errors.New("refused")
	}
	s.mu.Lock()
	s.got[ev.ID] = true
	s.mu.Unlock()
	return nil
}

// negsync names exactly the listed notes that didn't make it into the store,
// over a real NIP-77 session.
func TestNegsyncReportsWhichListedNotesAreMissing(t *testing.T) {
	skipWithoutSockets(t)
	relay := newFakeMac(t, true, 0)
	owner := newTestKey(t)
	ctx := context.Background()
	notes := spread(t, owner, 40, time.Minute)
	for _, ev := range notes {
		if err := relay.store.Store.SaveEvent(ctx, ev); err != nil {
			t.Fatal(err)
		}
	}
	store := &oneRefusedStore{refuse: notes[7].ID, got: map[string]bool{}}

	stats, err := negsync.Sync(ctx, store, relay.url, nostr.Filter{Authors: []string{owner.pk}}, negsync.Down)
	if err != nil {
		t.Fatal(err)
	}
	if stats.RemoteOnly != 40 || stats.Downloaded != 39 {
		t.Fatalf("remoteOnly %d downloaded %d, want 40 and 39", stats.RemoteOnly, stats.Downloaded)
	}
	if len(stats.Missing) != 1 || stats.Missing[0] != notes[7].ID {
		t.Fatalf("missing %v, want exactly the refused note", stats.Missing)
	}
}

// Tron's PR 1663 must-fix 1: a kind 5 arriving through negentropy while its
// target arrives on a paged lane must never leave the target stored. The
// deletion check and the store are one locked step on every lane.
func TestMoveInDeletionOnOneLaneTargetOnAnotherNeverBothStored(t *testing.T) {
	owner, db := moveInSetup(t, 30, "wss://neg.example", "wss://paged.example")
	const n = 1500
	targets := spread(t, owner, n, time.Second)
	deletions := make([]nostr.Event, n)
	for i, ev := range targets {
		deletions[i] = owner.sign(t, nostr.Event{Kind: nostr.KindDeletion, CreatedAt: ev.CreatedAt + 1, Tags: nostr.Tags{{"e", ev.ID}}})
	}
	prevSync, prevSup := importNegSync, importNegSupported
	importNegSupported = func(_ context.Context, url string) bool { return url == "wss://neg.example" }
	importNegSync = func(ctx context.Context, store nostr.RelayStore, _ string, _ nostr.Filter) (negsync.Stats, error) {
		for _, d := range deletions {
			_ = store.Publish(ctx, d)
		}
		return negsync.Stats{RemoteOnly: n, Downloaded: n}, nil
	}
	t.Cleanup(func() { importNegSync, importNegSupported = prevSync, prevSup })
	// The paged lane hands over the targets, one per page, as the deletions arrive.
	var mu sync.Mutex
	next := 0
	prev := importPage
	importPage = func(_ context.Context, url string, f nostr.Filter) ([]*nostr.Event, bool) {
		if url != "wss://paged.example" || len(f.IDs) > 0 {
			return nil, true
		}
		mu.Lock()
		defer mu.Unlock()
		if next >= n {
			return nil, true
		}
		page := targets[next:min(next+25, n)]
		next += len(page)
		return page, true
	}
	t.Cleanup(func() { importPage = prev })

	importOwnerNotes(context.Background())

	kept := 0
	for _, ev := range targets {
		if stored(t, db, ev.ID) {
			kept++
		}
	}
	if kept != 0 {
		t.Fatalf("%d of %d deleted notes stayed in the vault beside their deletion", kept, n)
	}
}

// Tron's PR 1663 must-fix 2: a relay sending made-up notes under the owner's
// key (bad id or signature) can't keep a lane paging: they never count as new.
func TestMoveInForgedNotesDoNotDriveTheLane(t *testing.T) {
	noNegentropy(t)
	owner, db := moveInSetup(t, 30, "wss://hostile.example")
	asks := 0
	prev := importPage
	importPage = func(_ context.Context, _ string, f nostr.Filter) ([]*nostr.Event, bool) {
		asks++
		page := make([]*nostr.Event, 0, 500)
		for i := 0; i < 500; i++ {
			at := nostr.Now() - nostr.Timestamp(asks*1000+i)
			if f.Until != nil && at > *f.Until {
				at = *f.Until - nostr.Timestamp(i)
			}
			ev := &nostr.Event{PubKey: owner.pk, Kind: nostr.KindTextNote, CreatedAt: at, Content: fmt.Sprint(asks, i), Tags: nostr.Tags{}}
			ev.ID = ev.GetID() // a real id, but never signed
			page = append(page, ev)
		}
		return page, true
	}
	t.Cleanup(func() { importPage = prev })

	importOwnerNotes(context.Background())

	if count(t, db, owner.pk) != 0 {
		t.Fatal("stored an unsigned note")
	}
	// The lane's first page has nothing real in it: done. The relay answered
	// (EOSE), so it isn't re-read by window either.
	if asks > 2 {
		t.Fatalf("forged notes drove %d requests", asks)
	}
}

// A relay that trickles real notes can't hold the import: its lane stops at
// importLaneDeadline and it is read window by window.
func TestMoveInTricklingRelayCannotHoldTheLane(t *testing.T) {
	noNegentropy(t)
	owner, db := moveInSetup(t, 30, "wss://trickle.example")
	prevDeadline := importLaneDeadline
	importLaneDeadline = 300 * time.Millisecond
	t.Cleanup(func() { importLaneDeadline = prevDeadline })
	// Held notes start an hour back, below everything the trickle sends:
	// the lane reads newest first, so the walk starts where it stopped and
	// reads only what is older (a relay's newest notes come in its lane).
	notes := make([]*nostr.Event, 400)
	for i := range notes {
		ev := owner.sign(t, nostr.Event{Kind: nostr.KindTextNote, CreatedAt: nostr.Timestamp(time.Now().Add(-time.Hour - time.Duration(i)*time.Hour).Unix()), Content: "note"})
		notes[i] = &ev
	}
	var mu sync.Mutex
	prev := importPage
	importPage = func(ctx context.Context, _ string, f nostr.Filter) ([]*nostr.Event, bool) {
		if f.Until == nil || *f.Until-*f.Since > 30*24*3600 {
			// The lane: one note a page, slowly, for as long as it's asked.
			select {
			case <-time.After(50 * time.Millisecond):
			case <-ctx.Done():
				return nil, false
			}
			// Always one more real note, just older than asked: it never ends.
			at := nostr.Now()
			if f.Until != nil {
				at = *f.Until - 1
			}
			ev := owner.sign(t, nostr.Event{Kind: nostr.KindTextNote, CreatedAt: at, Content: "trickle"})
			return []*nostr.Event{&ev}, false
		}
		mu.Lock()
		defer mu.Unlock()
		return (&pagingRelay{held: notes}).answer(f)
	}
	t.Cleanup(func() { importPage = prev })

	done := make(chan struct{})
	go func() { importOwnerNotes(context.Background()); close(done) }()
	select {
	case <-done:
	case <-time.After(20 * time.Second):
		t.Fatal("a trickling relay held the import")
	}
	for _, ev := range notes {
		if !stored(t, db, ev.ID) {
			t.Fatal("a note only the window walk could reach is missing")
		}
	}
}

// A relay that sends notes but never ends an answer with EOSE (it goes quiet
// instead; nostr-pub.wellorder.net, 2026-11-04) is alive: it is not dropped
// after a few windows with the rest of its history unread (Tidy import audit,
// item 1; this test used to assert the drop). Every window's note comes home.
func TestMoveInQuietRelayThatSendsNotesIsNotDropped(t *testing.T) {
	noNegentropy(t)
	owner, db := moveInSetup(t, 730, "wss://quiet.example")
	var mu sync.Mutex
	sent := map[nostr.Timestamp]bool{}
	prev := importPage
	importPage = func(_ context.Context, _ string, f nostr.Filter) ([]*nostr.Event, bool) {
		mu.Lock()
		defer mu.Unlock()
		if f.Until == nil {
			return nil, false // the whole-history lane: silent, so it is re-read by window
		}
		if sent[*f.Since] {
			return nil, false
		}
		sent[*f.Since] = true
		ev := owner.sign(t, nostr.Event{Kind: nostr.KindTextNote, CreatedAt: *f.Since + 1, Content: "one note, then quiet"})
		return []*nostr.Event{&ev}, false
	}
	t.Cleanup(func() { importPage = prev })

	importOwnerNotes(context.Background())

	if got, want := count(t, db, owner.pk), 73; got < want {
		t.Fatalf("vault has %d notes from a quiet relay with one a window, want all %d windows' (it was dropped)", got, want)
	}
}

// A relay that answers every window, but slowly, can't hold the walk past
// importWalkDeadline: it stops with what it has.
func TestOwnerWindowWalkStopsAtItsDeadline(t *testing.T) {
	noNegentropy(t)
	owner, _ := moveInSetup(t, 3650, "wss://slow.example")
	savedDeadline := importWalkDeadline
	importWalkDeadline = 300 * time.Millisecond
	t.Cleanup(func() { importWalkDeadline = savedDeadline })
	var mu sync.Mutex
	asked := 0
	prev := importPage
	importPage = func(ctx context.Context, _ string, f nostr.Filter) ([]*nostr.Event, bool) {
		mu.Lock()
		asked++
		mu.Unlock()
		select {
		case <-time.After(50 * time.Millisecond):
		case <-ctx.Done():
			return nil, false
		}
		if f.Until != nil && *f.Until <= *f.Since+1 {
			return nil, true
		}
		ev := owner.sign(t, nostr.Event{Kind: nostr.KindTextNote, CreatedAt: *f.Since + 1, Content: "slow but answers"})
		return []*nostr.Event{&ev}, true
	}
	t.Cleanup(func() { importPage = prev })

	start := time.Now()
	got := importOwnerWindows(context.Background(), []walkRelay{{url: "wss://slow.example", top: time.Now()}}, time.Now().AddDate(0, 0, -3650), []string{owner.pk}, func(*nostr.Event) bool { return true })
	took := time.Since(start)

	if took > 2*time.Second {
		t.Fatalf("the walk took %s, past its %s deadline", took, importWalkDeadline)
	}
	if got == 0 {
		t.Fatal("positive control: the walk stored nothing before its deadline")
	}
	if got >= 365 {
		t.Fatalf("the walk stored %d notes: it read all ~365 windows, the deadline did nothing", got)
	}
}

// A relay whose whole-history lane times out but that answers every window
// empty, with EOSE (nostr-pub.wellorder.net, 12 mini, 2026-11-05: ~140
// windows from Jan 2023, the screen stuck on "Jan 2023"). Empty answers widen
// the window, so four years take a few dozen asks at most, the one recent
// note still comes, and every window logs a line the import screen reads.
func TestMoveInEmptyWindowsWidenInsteadOfWalkingEveryOne(t *testing.T) {
	noNegentropy(t)
	owner, db := moveInSetup(t, 1400, "wss://empty.example")
	recent := owner.sign(t, nostr.Event{Kind: nostr.KindTextNote, CreatedAt: nostr.Timestamp(time.Now().Add(-5 * 24 * time.Hour).Unix()), Content: "the one recent note"})
	var mu sync.Mutex
	windows := 0
	prev := importPage
	importPage = func(_ context.Context, _ string, f nostr.Filter) ([]*nostr.Event, bool) {
		mu.Lock()
		defer mu.Unlock()
		if f.Until == nil {
			return nil, false // the whole-history lane: times out, so it is walked
		}
		windows++
		if f.Matches(&recent) {
			return []*nostr.Event{&recent}, true
		}
		return nil, true // empty, with EOSE
	}
	t.Cleanup(func() { importPage = prev })
	var buf bytes.Buffer
	prevOut := log.Writer()
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(prevOut) })

	importOwnerNotes(context.Background())

	if windows > 30 {
		t.Fatalf("an empty relay was asked %d times for 1,400 days: the walk did not widen (10-day windows: ~140)", windows)
	}
	if got := count(t, db, owner.pk); got != 1 {
		t.Fatalf("vault has %d notes, want the 1 recent one: widening skipped it", got)
	}
	out := buf.String()
	first := "No notes found for " + time.Now().AddDate(0, 0, -1400).Format(layout)
	if !strings.Contains(out, first) {
		t.Fatalf("the walk's first window logged no line the import screen reads (%q):\n%s", first, out)
	}
	if !strings.Contains(out, "(window by window)") {
		t.Fatalf("the window with the recent note logged no Imported line:\n%s", out)
	}
}

// A relay that times out on anything wider than 30 days: a widened window it
// can't answer is read again 10 days at a time, so widening never costs a
// note (and the timeout is not counted against the relay).
func TestMoveInWidenedWindowThatTimesOutIsReadAgainNarrow(t *testing.T) {
	noNegentropy(t)
	owner, db := moveInSetup(t, 400, "wss://narrow.example")
	notes := spread(t, owner, 480, time.Hour) // the last 20 days
	r := &pagingRelay{held: notes}
	var mu sync.Mutex
	prev := importPage
	importPage = func(_ context.Context, _ string, f nostr.Filter) ([]*nostr.Event, bool) {
		if f.Until == nil || f.Since == nil || *f.Until-*f.Since > 30*24*3600 {
			return nil, false // too wide: times out
		}
		mu.Lock()
		defer mu.Unlock()
		return r.answer(f)
	}
	t.Cleanup(func() { importPage = prev })

	importOwnerNotes(context.Background())

	if got := count(t, db, owner.pk); got != 480 {
		t.Fatalf("vault has %d of 480 notes: a widened window that timed out was not read again narrow", got)
	}
}

// A lane that ends with an empty EOSE has nothing older: it is asked once and
// never walked window by window.
func TestMoveInEmptyLaneIsNotWalked(t *testing.T) {
	noNegentropy(t)
	_, _ = moveInSetup(t, 1400, "wss://nothing.example")
	asked := 0
	prev := importPage
	importPage = func(context.Context, string, nostr.Filter) ([]*nostr.Event, bool) {
		asked++
		return nil, true
	}
	t.Cleanup(func() { importPage = prev })

	importOwnerNotes(context.Background())

	if asked != 1 {
		t.Fatalf("an empty lane was asked %d times, want 1 (no window walk)", asked)
	}
}

// A lane that got the newest notes and then stopped: the walk starts where it
// stopped and reads only what is older, so it never spends its time on what
// the lane already read, and a walk cut by its deadline can't leave a gap in
// the middle of the history (Tidy import audit, item 2).
func TestMoveInWalkStartsWhereTheLaneStopped(t *testing.T) {
	noNegentropy(t)
	owner, db := moveInSetup(t, 100, "wss://tired.example")
	notes := spread(t, owner, 1500, time.Hour) // ~62 days
	r := &pagingRelay{held: notes}
	var mu sync.Mutex
	lanePages, laneDone := 0, false
	var laneOldest nostr.Timestamp
	var walkTops []nostr.Timestamp
	prev := importPage
	importPage = func(_ context.Context, _ string, f nostr.Filter) ([]*nostr.Event, bool) {
		mu.Lock()
		defer mu.Unlock()
		if !laneDone {
			lanePages++
			if lanePages > 2 {
				laneDone = true   // everything asked after this is the walk
				return nil, false // the lane's third page never comes
			}
			evs, eose := r.answer(f)
			for _, ev := range evs {
				if laneOldest == 0 || ev.CreatedAt < laneOldest {
					laneOldest = ev.CreatedAt
				}
			}
			return evs, eose
		}
		walkTops = append(walkTops, *f.Until)
		return r.answer(f)
	}
	t.Cleanup(func() { importPage = prev })

	importOwnerNotes(context.Background())

	if got := count(t, db, owner.pk); got != 1500 {
		t.Fatalf("vault has %d of 1500 notes", got)
	}
	for _, top := range walkTops {
		if top > laneOldest+1 {
			t.Fatalf("the walk asked up to %s, above where the lane stopped (%s): it re-read what the lane had",
				top.Time().Format(time.RFC3339), laneOldest.Time().Format(time.RFC3339))
		}
	}
	if len(walkTops) == 0 {
		t.Fatal("positive control: the walk never ran")
	}
}

// One rate-limit answer used to ban a relay for 24 h and drop its whole
// history from the import (Tidy import audit, item 7). A relay that refused
// us during the import is asked once more after a pause.
func TestMoveInRateLimitedRelayIsRetriedOnce(t *testing.T) {
	noNegentropy(t)
	owner, db := moveInSetup(t, 100, "wss://busy.example")
	prevBackoff := importRefusalBackoff
	importRefusalBackoff = 10 * time.Millisecond
	t.Cleanup(func() {
		importRefusalBackoff = prevBackoff
		relayBans.Delete(nostr.NormalizeURL("wss://busy.example"))
	})
	notes := spread(t, owner, 300, time.Hour)
	r := &pagingRelay{held: notes}
	var mu sync.Mutex
	refusals := 0
	prev := importPage
	importPage = func(_ context.Context, url string, f nostr.Filter) ([]*nostr.Event, bool) {
		mu.Lock()
		defer mu.Unlock()
		if relayBanned(url) {
			return nil, false // what the pool's dial gate does
		}
		if refusals == 0 {
			refusals++
			noteRelayRefusal(url, errors.New("rate-limited: slow down"))
			return nil, false
		}
		return r.answer(f)
	}
	t.Cleanup(func() { importPage = prev })

	resetImportRetries(t)
	beginImportRefusalRetries() // runImport's first step
	importOwnerNotes(context.Background())

	if got := count(t, db, owner.pk); got != 300 {
		t.Fatalf("vault has %d of 300 notes: one rate-limit answer dropped the relay", got)
	}
}

// A second refusal stands: the retry is spent, the relay is dropped and the
// import ends (it doesn't wait on a relay that keeps saying no).
func TestMoveInRelayRefusingTwiceIsDropped(t *testing.T) {
	noNegentropy(t)
	_, _ = moveInSetup(t, 100, "wss://no.example")
	prevBackoff := importRefusalBackoff
	importRefusalBackoff = 10 * time.Millisecond
	t.Cleanup(func() {
		importRefusalBackoff = prevBackoff
		relayBans.Delete(nostr.NormalizeURL("wss://no.example"))
	})
	var mu sync.Mutex
	asked := 0
	prev := importPage
	importPage = func(_ context.Context, url string, f nostr.Filter) ([]*nostr.Event, bool) {
		mu.Lock()
		defer mu.Unlock()
		if relayBanned(url) {
			return nil, false
		}
		asked++
		noteRelayRefusal(url, errors.New("rate-limited: slow down"))
		return nil, false
	}
	t.Cleanup(func() { importPage = prev })

	resetImportRetries(t)
	beginImportRefusalRetries() // runImport's first step
	importOwnerNotes(context.Background())

	if asked != 2 {
		t.Fatalf("a relay refusing every time reached the relay %d times, want 2 (once, then its one retry)", asked)
	}
}

// A refusal given before the notes start (WoT init and the list-history scan
// dial the same relays first) still gets its one retry: the import's retry
// budget starts at the top of runImport, not in importOwnerNotes (Tron, #1721).
func TestMoveInRefusalBeforeNotesStartIsRetried(t *testing.T) {
	noNegentropy(t)
	owner, db := moveInSetup(t, 100, "wss://early.example")
	prevBackoff := importRefusalBackoff
	importRefusalBackoff = 10 * time.Millisecond
	t.Cleanup(func() {
		importRefusalBackoff = prevBackoff
		relayBans.Delete(nostr.NormalizeURL("wss://early.example"))
	})
	notes := spread(t, owner, 300, time.Hour)
	r := &pagingRelay{held: notes}
	var mu sync.Mutex
	prev := importPage
	importPage = func(_ context.Context, url string, f nostr.Filter) ([]*nostr.Event, bool) {
		mu.Lock()
		defer mu.Unlock()
		if relayBanned(url) {
			return nil, false // what the pool's dial gate does
		}
		return r.answer(f)
	}
	t.Cleanup(func() { importPage = prev })

	resetImportRetries(t)
	beginImportRefusalRetries()
	// A 429 during WoT init, before importOwnerNotes runs.
	noteRelayRefusal("wss://early.example", errors.New("rate-limited: slow down"))
	importOwnerNotes(context.Background())

	if got := count(t, db, owner.pk); got != 300 {
		t.Fatalf("vault has %d of 300 notes: a refusal before the notes started never got its retry", got)
	}
}

// An old version of the owner's list that a seed relay still serves is an
// imported version: it goes to the import store, never into the vault's own
// list history, where it could trim what the vault kept (Tidy import audit,
// item 11; the erosion PR 1637 / 5f00485d9 fixed only for the history scan).
func TestMoveInOwnerListVersionsAreFiledAsImported(t *testing.T) {
	noNegentropy(t)
	owner, inner := moveInSetup(t, 100, "wss://lists.example")
	history := newTestBackend(t, "lists")
	if err := history.Init(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(history.Close)
	withImportStore(t, func(name string) DBBackend { return newTestBackend(t, name) })
	prevLists := listsDB
	listsDB = history
	t.Cleanup(func() { listsDB = prevLists })
	outboxDB = newListHistoryDB(inner, func() DBBackend { return listsDB })

	now := time.Now()
	var served []*nostr.Event
	for i := range 3 {
		ev := owner.sign(t, nostr.Event{Kind: 10003, CreatedAt: nostr.Timestamp(now.Add(-time.Duration(i+1) * 24 * time.Hour).Unix()), Tags: nostr.Tags{{"e", fmt.Sprintf("%064d", i)}}})
		served = append(served, &ev)
	}
	r := &pagingRelay{held: served}
	var mu sync.Mutex
	prev := importPage
	importPage = func(_ context.Context, _ string, f nostr.Filter) ([]*nostr.Event, bool) {
		mu.Lock()
		defer mu.Unlock()
		return r.answer(f)
	}
	t.Cleanup(func() { importPage = prev })

	importOwnerNotes(context.Background())

	if got := count(t, history, owner.pk); got != 0 {
		t.Fatalf("the vault's own list history got %d imported versions: an import can trim what it kept", got)
	}
	if got := count(t, listsImportDB, owner.pk); got != 3 {
		t.Fatalf("the import store has %d of the 3 versions served", got)
	}
}
