package main

import (
	"context"
	"fmt"
	"net/http/httptest"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/fiatjaf/khatru"
	"github.com/nbd-wtf/go-nostr"
)

// Moving in's paged window read (import_paging.go), with fake relays: nothing is opened or published.

type pagingRelay struct {
	held  []*nostr.Event
	cap   int // the relay's own answer cap (0: the filter's limit)
	quiet int // after this many pages, it answers without EOSE and only half a page
	asks  int
}

func (r *pagingRelay) answer(f nostr.Filter) ([]*nostr.Event, bool) {
	r.asks++
	var hits []*nostr.Event
	for _, ev := range r.held {
		if f.Matches(ev) {
			hits = append(hits, ev)
		}
	}
	sort.SliceStable(hits, func(i, j int) bool {
		if hits[i].CreatedAt != hits[j].CreatedAt {
			return hits[i].CreatedAt > hits[j].CreatedAt
		}
		return hits[i].ID < hits[j].ID
	})
	n := f.Limit
	if r.cap > 0 && r.cap < n {
		n = r.cap
	}
	if len(hits) > n {
		hits = hits[:n]
	}
	if r.quiet > 0 && r.asks > r.quiet {
		return hits[:(len(hits)+1)/2], false // went quiet mid-answer
	}
	return hits, true
}

func withPagingRelays(t *testing.T, relays map[string]*pagingRelay) {
	t.Helper()
	var mu sync.Mutex
	prev := importPage
	importPage = func(_ context.Context, url string, f nostr.Filter) ([]*nostr.Event, bool) {
		mu.Lock()
		defer mu.Unlock()
		r, ok := relays[url]
		if !ok {
			return nil, false
		}
		return r.answer(f)
	}
	t.Cleanup(func() { importPage = prev })
}

// notes: n of the owner's notes, one a second going back from `newest`.
func notesOf(t *testing.T, k testKey, n int, newest nostr.Timestamp) []*nostr.Event {
	t.Helper()
	out := make([]*nostr.Event, n)
	for i := range out {
		ev := k.sign(t, nostr.Event{Kind: nostr.KindTextNote, CreatedAt: newest - nostr.Timestamp(i), Content: fmt.Sprint("note ", i)})
		out[i] = &ev
	}
	return out
}

func windowFilter(pk string, since, until nostr.Timestamp) nostr.Filter {
	return nostr.Filter{Authors: []string{pk}, Since: &since, Until: &until}
}

// The bug: one REQ per window, so a relay's answer cap (here 300) kept only the newest 300 of a busy window.
func TestWindowPagedPastTheRelayCap(t *testing.T) {
	owner := newTestKey(t)
	held := notesOf(t, owner, 1200, 100_000)
	r := &pagingRelay{held: held, cap: 300}
	withPagingRelays(t, map[string]*pagingRelay{"wss://busy.example": r})
	got := map[string]bool{}
	res := fetchWindowPaged(context.Background(), []string{"wss://busy.example"}, windowFilter(owner.pk, 0, 100_000), func(ev *nostr.Event) { got[ev.ID] = true })
	if res.Notes != 1200 || len(got) != 1200 {
		t.Fatalf("kept %d (%d handed over), want all 1200", len(got), res.Notes)
	}
	if len(res.Short) != 0 {
		t.Fatalf("short: %v", res.Short)
	}
	if r.asks < 5 {
		t.Fatalf("asked %d pages, want at least 5 (1200 at 300 a page, then an empty one)", r.asks)
	}
}

// Since bounds it: notes before the window are never asked for or kept.
func TestWindowPagedStaysInTheWindow(t *testing.T) {
	owner := newTestKey(t)
	held := notesOf(t, owner, 100, 1_000)
	withPagingRelays(t, map[string]*pagingRelay{"wss://a.example": {held: held, cap: 7}})
	res := fetchWindowPaged(context.Background(), []string{"wss://a.example"}, windowFilter(owner.pk, 951, 1_000), func(*nostr.Event) {})
	if res.Notes != 50 {
		t.Fatalf("kept %d, want the window's 50", res.Notes)
	}
}

// A relay that goes quiet mid-page doesn't end its window: what it sent is kept and it is asked again from there.
func TestWindowPagedGoesOnAfterAQuietPage(t *testing.T) {
	owner := newTestKey(t)
	held := notesOf(t, owner, 400, 50_000)
	withPagingRelays(t, map[string]*pagingRelay{"wss://slow.example": {held: held, cap: 100, quiet: 1}})
	res := fetchWindowPaged(context.Background(), []string{"wss://slow.example"}, windowFilter(owner.pk, 0, 50_000), func(*nostr.Event) {})
	if res.Notes != 400 {
		t.Fatalf("kept %d, want all 400 in half-pages", res.Notes)
	}
}

// Two relays holding the same notes: each kept once; a stranger's note a relay slips in is dropped.
func TestWindowPagedKeepsEachNoteOnce(t *testing.T) {
	owner, stranger := newTestKey(t), newTestKey(t)
	held := notesOf(t, owner, 30, 10_000)
	other := stranger.sign(t, nostr.Event{Kind: nostr.KindTextNote, CreatedAt: 9_999, Content: "not yours"})
	withPagingRelays(t, map[string]*pagingRelay{
		"wss://a.example": {held: held, cap: 10},
		"wss://b.example": {held: append(append([]*nostr.Event{}, held[:20]...), &other), cap: 4},
	})
	importPageWrap := importPage
	importPage = func(ctx context.Context, url string, f nostr.Filter) ([]*nostr.Event, bool) {
		evs, ok := importPageWrap(ctx, url, f)
		if url == "wss://b.example" {
			evs = append(evs, &other) // a relay may send anything
		}
		return evs, ok
	}
	t.Cleanup(func() { importPage = importPageWrap })
	var mu sync.Mutex
	counts := map[string]int{}
	res := fetchWindowPaged(context.Background(), []string{"wss://a.example", "wss://b.example"}, windowFilter(owner.pk, 0, 10_000), func(ev *nostr.Event) {
		mu.Lock()
		counts[ev.ID]++
		mu.Unlock()
	})
	if res.Notes != 30 || len(counts) != 30 {
		t.Fatalf("kept %d / %d, want 30", res.Notes, len(counts))
	}
	for id, n := range counts {
		if n != 1 || id == other.ID {
			t.Fatalf("%s handed over %d times", id, n)
		}
	}
}

// A relay that stops answering after its first pages is named, so the log can say the window may be short.
func TestWindowPagedNamesARelayThatStopped(t *testing.T) {
	owner := newTestKey(t)
	held := notesOf(t, owner, 50, 5_000)
	r := &pagingRelay{held: held, cap: 10}
	withPagingRelays(t, map[string]*pagingRelay{"wss://gone.example": r})
	prev := importPage
	importPage = func(ctx context.Context, url string, f nostr.Filter) ([]*nostr.Event, bool) {
		if f.Until != nil && *f.Until < 4_985 {
			return nil, false // dropped off after two pages
		}
		return prev(ctx, url, f)
	}
	t.Cleanup(func() { importPage = prev })
	res := fetchWindowPaged(context.Background(), []string{"wss://gone.example"}, windowFilter(owner.pk, 0, 5_000), func(*nostr.Event) {})
	// 10, then 9 new (each page repeats the second it starts from).
	if res.Notes != 19 || len(res.Short) != 1 || res.Short[0] != "wss://gone.example" {
		t.Fatalf("result %+v, want 19 notes and the relay named", res)
	}
}

// More notes in one second than a page holds can't be paged through (until is whole seconds): the paging steps a
// second back past them and goes on with the older notes, so only that second is short.
func TestWindowPagedEndsOnASecondFullerThanAPage(t *testing.T) {
	owner := newTestKey(t)
	held := make([]*nostr.Event, 12)
	for i := range held {
		ev := owner.sign(t, nostr.Event{Kind: nostr.KindTextNote, CreatedAt: 777, Content: fmt.Sprint(i)})
		held[i] = &ev
	}
	held = append(held, notesOf(t, owner, 20, 776)...)
	withPagingRelays(t, map[string]*pagingRelay{"wss://a.example": {held: held, cap: 5}})
	res := fetchWindowPaged(context.Background(), []string{"wss://a.example"}, windowFilter(owner.pk, 0, 1_000), func(*nostr.Event) {})
	if res.Notes != 25 {
		t.Fatalf("kept %d, want 5 from the crowded second and all 20 older ones", res.Notes)
	}
}

func TestWindowPagedStopsWhenCancelled(t *testing.T) {
	owner := newTestKey(t)
	held := notesOf(t, owner, 100, 9_000)
	withPagingRelays(t, map[string]*pagingRelay{"wss://a.example": {held: held, cap: 10}})
	ctx, cancel := context.WithCancel(context.Background())
	n := 0
	res := fetchWindowPaged(ctx, []string{"wss://a.example"}, windowFilter(owner.pk, 0, 9_000), func(*nostr.Event) {
		n++
		if n == 15 {
			cancel()
		}
	})
	if res.Notes != 19 {
		t.Fatalf("kept %d, want the two pages in hand when it was stopped (10 + 9 new)", res.Notes)
	}
}

// End to end over real sockets: a khatru relay that caps every REQ at 50 holds 400 of the owner's notes in one
// window, and a second relay never answers. importOwnerNotes keeps all 400 (one REQ kept 50) and the dead relay only
// costs one idle timeout, not the window.
func TestImportOwnerNotesPagesPastARelayCap(t *testing.T) {
	skipWithoutSockets(t)
	owner := newTestKey(t)
	savedCfg, savedDB, savedPool, savedReach, savedIdle, savedCaps := config, outboxDB, pool, reachableImportRelays.Load(), importIdleTimeout, negCapsFile
	t.Cleanup(func() {
		config, outboxDB, pool, importIdleTimeout, negCapsFile = savedCfg, savedDB, savedPool, savedIdle, savedCaps
		reachableImportRelays.Store(savedReach)
		resetNegCaps()
	})
	// The import tries negentropy first: keep its capability answers out of the package dir.
	negCapsFile = filepath.Join(t.TempDir(), "negentropy_caps.json")
	resetNegCaps()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	setupSyncConfig(owner.pk)
	config.OwnerPubKey = owner.pk
	config.ImportStartDate = time.Now().AddDate(0, 0, -2).Format(layout)
	reachableImportRelays.Store(nil)
	pool = nostr.NewSimplePool(ctx)
	importIdleTimeout = 300 * time.Millisecond

	deletionBackends(t, func(t *testing.T, db DBBackend) {
		busy := newFakeMac(t, false, 50)
		ids := busy.seed(t, owner.sk, 400, time.Now().Add(-30*time.Hour), time.Now().Add(-time.Hour), nil)
		stall := make(chan struct{})
		t.Cleanup(func() { close(stall) })
		dead := newFakeMac(t, false, 0, func(ctx context.Context, _ nostr.Filter) (bool, string) {
			select { // holds the REQ: no event, no EOSE
			case <-stall:
			case <-ctx.Done():
			}
			return true, "blocked: never answers"
		})
		config.ImportSeedRelays = []string{busy.url, dead.url}
		outboxDB = db

		start := time.Now()
		importOwnerNotes(ctx)
		took := time.Since(start)

		missing := 0
		for id := range ids {
			if !stored(t, db, id) {
				missing++
			}
		}
		if missing != 0 {
			t.Fatalf("%d of 400 notes missing after the import (a single capped REQ keeps 50)", missing)
		}
		if took > 15*time.Second {
			t.Fatalf("the silent relay held the import %v", took)
		}
	})
}

// Tron's PR 1654 must-fix 2: a relay whose recent notes a faster relay already sent must still page on to the older
// notes only it holds. Relay a (the newest 20) answers first; relay b holds all 30, ten of them nowhere else.
func TestWindowPagedSlowRelayStillReachesItsOwnOlderNotes(t *testing.T) {
	owner := newTestKey(t)
	held := notesOf(t, owner, 30, 10_000)
	withPagingRelays(t, map[string]*pagingRelay{
		"wss://fast.example": {held: held[:20], cap: 10},
		"wss://slow.example": {held: held, cap: 10},
	})
	fastDone := make(chan struct{})
	inner := importPage
	importPage = func(ctx context.Context, url string, f nostr.Filter) ([]*nostr.Event, bool) {
		if url == "wss://slow.example" {
			<-fastDone
		}
		evs, ok := inner(ctx, url, f)
		if url == "wss://fast.example" && len(evs) == 0 {
			close(fastDone) // fast has nothing older: let slow start
		}
		return evs, ok
	}
	t.Cleanup(func() { importPage = inner })
	res := fetchWindowPaged(context.Background(), []string{"wss://fast.example", "wss://slow.example"}, windowFilter(owner.pk, 0, 10_000), func(*nostr.Event) {})
	if res.Notes != 30 {
		t.Fatalf("kept %d, want 30: the slow relay's ten older notes were lost", res.Notes)
	}
}

// Tron's PR 1654 must-fix 1, over a real socket: a relay that replays one genuine owner note every 100 ms and never
// sends EOSE must not hold the window open. Repeats don't restart the idle wait.
func TestImportPageEndsOnATrickleOfRepeats(t *testing.T) {
	skipWithoutSockets(t)
	owner := newTestKey(t)
	savedPool, savedIdle := pool, importIdleTimeout
	t.Cleanup(func() { pool, importIdleTimeout = savedPool, savedIdle })
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	pool = nostr.NewSimplePool(ctx)
	importIdleTimeout = 300 * time.Millisecond

	now := nostr.Now()
	ev := owner.sign(t, nostr.Event{Kind: 1, CreatedAt: now - 3600, Content: "hi"})
	rl := khatru.NewRelay()
	rl.QueryEvents = append(rl.QueryEvents, func(ctx context.Context, _ nostr.Filter) (chan *nostr.Event, error) {
		ch := make(chan *nostr.Event)
		go func() {
			for {
				select {
				case <-ctx.Done():
					return
				case <-time.After(100 * time.Millisecond):
					e := ev
					select {
					case ch <- &e:
					case <-ctx.Done():
						return
					}
				}
			}
		}()
		return ch, nil
	})
	srv := httptest.NewServer(rl)
	t.Cleanup(srv.Close)
	url := "ws" + strings.TrimPrefix(srv.URL, "http")

	since := now - 86400
	done := make(chan windowResult, 1)
	go func() {
		done <- fetchWindowPaged(ctx, []string{url}, windowFilter(owner.pk, since, now), func(*nostr.Event) {})
	}()
	select {
	case r := <-done:
		if r.Notes != 1 {
			t.Fatalf("result %+v, want the one note once", r)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("a relay replaying one note held the window open past 5 s (idle wait 300 ms)")
	}
}

// A full page ends the request at once, and the hard per-page limit ends one that trickles new notes forever.
func TestImportPageHardLimit(t *testing.T) {
	skipWithoutSockets(t)
	owner := newTestKey(t)
	savedPool, savedIdle, savedMax := pool, importIdleTimeout, importPageMax
	t.Cleanup(func() { pool, importIdleTimeout, importPageMax = savedPool, savedIdle, savedMax })
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	pool = nostr.NewSimplePool(ctx)
	importIdleTimeout = time.Second
	importPageMax = 700 * time.Millisecond

	now := nostr.Now()
	rl := khatru.NewRelay()
	rl.QueryEvents = append(rl.QueryEvents, func(ctx context.Context, _ nostr.Filter) (chan *nostr.Event, error) {
		ch := make(chan *nostr.Event)
		go func() {
			for i := 0; ; i++ { // a new genuine note every 50 ms, never EOSE
				e := owner.sign(t, nostr.Event{Kind: 1, CreatedAt: now - nostr.Timestamp(i), Content: fmt.Sprint(i)})
				select {
				case <-ctx.Done():
					return
				case <-time.After(50 * time.Millisecond):
				}
				select {
				case ch <- &e:
				case <-ctx.Done():
					return
				}
			}
		}()
		return ch, nil
	})
	srv := httptest.NewServer(rl)
	t.Cleanup(srv.Close)
	url := "ws" + strings.TrimPrefix(srv.URL, "http")

	start := time.Now()
	evs, eose := askRelayIdle(ctx, url, nostr.Filter{Authors: []string{owner.pk}, Limit: 500})
	if took := time.Since(start); took > 2*time.Second || eose || len(evs) == 0 {
		t.Fatalf("took %v, eose %v, %d notes: want ended by the 700 ms page limit", took, eose, len(evs))
	}
	start = time.Now()
	evs, eose = askRelayIdle(ctx, url, nostr.Filter{Authors: []string{owner.pk}, Limit: 3})
	if took := time.Since(start); len(evs) != 3 || !eose || took > 500*time.Millisecond {
		t.Fatalf("took %v, eose %v, %d notes: a full page of 3 should end at once", took, eose, len(evs))
	}
}
