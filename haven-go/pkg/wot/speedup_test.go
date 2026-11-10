package wot

import (
	"context"
	"encoding/json"
	"maps"
	"net"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/fiatjaf/khatru"
	"github.com/nbd-wtf/go-nostr"
)

// liveRelay is a seed relay whose events can change between rebuilds, which
// records the filters it was asked, and which can be slow or never send EOSE.
type liveRelay struct {
	url     string
	mu      sync.Mutex
	events  map[string]*nostr.Event // newest kind 3 per author
	filters []nostr.Filter
	delay   time.Duration
	hang    bool // never EOSE: QueryEvents blocks until the request ends
	// hangOn, when set, picks requests that get nothing at all, not even
	// EOSE, until they end.
	hangOn func(nostr.Filter) bool
}

func newLiveRelay(t *testing.T, events ...*nostr.Event) *liveRelay {
	lr := &liveRelay{events: map[string]*nostr.Event{}}
	lr.put(events...)
	rl := khatru.NewRelay()
	rl.QueryEvents = append(rl.QueryEvents, func(ctx context.Context, f nostr.Filter) (chan *nostr.Event, error) {
		lr.mu.Lock()
		lr.filters = append(lr.filters, f)
		var match []*nostr.Event
		for _, ev := range lr.events {
			if f.Matches(ev) {
				match = append(match, ev)
			}
		}
		delay, hang := lr.delay, lr.hang
		if lr.hangOn != nil && lr.hangOn(f) {
			match, delay, hang = nil, 0, true
		}
		lr.mu.Unlock()
		ch := make(chan *nostr.Event, len(match))
		go func() {
			defer close(ch)
			// A slow relay is slow to send its events, not only its EOSE.
			select {
			case <-time.After(delay):
			case <-ctx.Done():
				return
			}
			for _, ev := range match {
				ch <- ev
			}
			if hang {
				<-ctx.Done()
			}
		}()
		return ch, nil
	})
	srv := httptest.NewServer(rl)
	t.Cleanup(srv.Close)
	lr.url = "ws" + strings.TrimPrefix(srv.URL, "http")
	return lr
}

func (lr *liveRelay) put(events ...*nostr.Event) {
	lr.mu.Lock()
	defer lr.mu.Unlock()
	for _, ev := range events {
		lr.events[ev.PubKey] = ev
	}
}

func (lr *liveRelay) asked() []nostr.Filter {
	lr.mu.Lock()
	defer lr.mu.Unlock()
	return slices.Clone(lr.filters)
}

func (lr *liveRelay) forget() {
	lr.mu.Lock()
	lr.filters = nil
	lr.mu.Unlock()
}

// listAt is k's follow list stamped at, so a rebuild can tell newer from older.
func (k testKey) listAt(t *testing.T, at nostr.Timestamp, follows ...testKey) *nostr.Event {
	ev := k.followList(t, follows...)
	ev.CreatedAt = at
	if err := ev.Sign(k.sk); err != nil {
		t.Fatal(err)
	}
	return ev
}

func urls(relays ...*liveRelay) []string {
	out := make([]string, len(relays))
	for i, r := range relays {
		out[i] = r.url
	}
	return out
}

// One relay that never sends EOSE no longer holds a batch for the whole
// fetch timeout: once three relays have answered, it gets listGrace more.
// Before, every batch waited for every relay (the 7.6 s wellorder case).
func TestListFetchEndsAfterQuorum(t *testing.T) {
	a, b, x := newTestKey(t), newTestKey(t), newTestKey(t)
	fast1 := newLiveRelay(t, a.followList(t, x))
	fast2 := newLiveRelay(t, b.followList(t, x))
	fast3 := newLiveRelay(t)
	stuck := newLiveRelay(t)
	stuck.hang = true

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	start := time.Now()
	got := fetchLatestLists(ctx, nostr.NewSimplePool(ctx), urls(fast1, fast2, fast3, stuck),
		nostr.Filter{Kinds: []int{nostr.KindFollowList}, Authors: []string{a.pk, b.pk}})
	took := time.Since(start)

	if took > listGrace+3*time.Second {
		t.Fatalf("fetch took %v with one relay that never sends EOSE; want about listGrace (%v)", took, listGrace)
	}
	if !got.complete {
		t.Error("three of four relays sent EOSE: the fetch is complete")
	}
	if len(got.lists) != 2 {
		t.Errorf("got %d lists, want a's and b's", len(got.lists))
	}
}

// A relay that is slow but does answer within the grace still counts: the
// grace is for lists only it has.
func TestListFetchWaitsTheGraceForASlowRelay(t *testing.T) {
	a, b, x := newTestKey(t), newTestKey(t), newTestKey(t)
	r1, r2, r3 := newLiveRelay(t), newLiveRelay(t), newLiveRelay(t)
	slow := newLiveRelay(t, b.followList(t, x))
	slow.delay = 300 * time.Millisecond
	r1.put(a.followList(t, x))

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	got := fetchLatestLists(ctx, nostr.NewSimplePool(ctx), urls(r1, r2, r3, slow),
		nostr.Filter{Kinds: []int{nostr.KindFollowList}, Authors: []string{a.pk, b.pk}})
	if got.lists[b.pk] == nil {
		t.Error("the slow relay's list, sent well inside the grace, was dropped")
	}
}

// With fewer relays than the quorum, every one of them must answer, and a
// fetch where none can be reached is never complete.
func TestListFetchCompleteness(t *testing.T) {
	a, x := newTestKey(t), newTestKey(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	f := nostr.Filter{Kinds: []int{nostr.KindFollowList}, Authors: []string{a.pk}}

	one := newLiveRelay(t, a.followList(t, x))
	if got := fetchLatestLists(ctx, nostr.NewSimplePool(ctx), urls(one, one), f); !got.complete || len(got.lists) != 1 {
		t.Errorf("one relay (listed twice) answered: complete %v, %d lists", got.complete, len(got.lists))
	}
	if got := fetchLatestLists(ctx, nostr.NewSimplePool(ctx), []string{"ws://127.0.0.1:1"}, f); got.complete {
		t.Error("an unreachable relay made the fetch complete")
	}
	if got := fetchLatestLists(ctx, nostr.NewSimplePool(ctx), nil, f); got.complete {
		t.Error("no relays made the fetch complete")
	}
	short, stop := context.WithTimeout(ctx, 300*time.Millisecond)
	defer stop()
	stuck := newLiveRelay(t, a.followList(t, x))
	stuck.hang = true
	got := fetchLatestLists(short, nostr.NewSimplePool(ctx), urls(stuck), f)
	if got.complete {
		t.Error("a relay that never sent EOSE made the fetch complete")
	}
	if len(got.lists) != 1 {
		t.Error("what arrived before the timeout must be kept")
	}
}

// Batches are fetched at once, not one after another: three batches from a
// relay that takes delay per request take about one delay, not three.
func TestListBatchesRunInParallel(t *testing.T) {
	owner := newTestKey(t)
	n := 2*listBatchSize + 10 // three batches
	follows := make([]testKey, n)
	for i := range follows {
		follows[i] = newTestKey(t)
	}
	relay := newLiveRelay(t)
	const delay = 600 * time.Millisecond
	relay.delay = delay

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	wt := NewSimpleInMemory(nostr.NewSimplePool(ctx), map[string]struct{}{owner.pk: {}},
		urls(relay), 3, 1, 30, filepath.Join(t.TempDir(), "wot_cache.json"), 60)
	list := owner.followList(t, follows...)
	wt.LocalFollowLists = func() []*nostr.Event { return []*nostr.Event{list} }

	start := time.Now()
	wt.Refresh(ctx)
	took := time.Since(start)

	batches := 0
	for _, f := range relay.asked() {
		if len(f.Authors) > 1 {
			batches++
		}
	}
	if batches != 3 {
		t.Fatalf("relay was asked %d list batches, want 3", batches)
	}
	// The owner-list fetch costs one delay too; sequential batches cost 3 more.
	if took >= 3*delay {
		t.Fatalf("rebuild took %v: the 3 batches ran one after another (each %v)", took, delay)
	}
}

type graphState struct {
	pubkeys map[string]bool
	vouches map[string]int
	links   map[string][]int
}

func readGraph(t *testing.T, path string) graphState {
	t.Helper()
	var c wotCache
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, &c); err != nil {
		t.Fatal(err)
	}
	var l wotLinks
	if data, err := os.ReadFile(filepath.Join(filepath.Dir(path), linksFile)); err == nil {
		_ = json.Unmarshal(data, &l)
	}
	return graphState{c.Pubkeys, c.Vouches, l.Links}
}

func sameGraph(t *testing.T, label string, got, want graphState) {
	t.Helper()
	if !maps.Equal(got.pubkeys, want.pubkeys) {
		t.Errorf("%s: graph %d people, a full rebuild of the same lists has %d", label, len(got.pubkeys), len(want.pubkeys))
	}
	if !maps.Equal(got.vouches, want.vouches) {
		t.Errorf("%s: vouches differ from a full rebuild's", label)
	}
	if !maps.EqualFunc(got.links, want.links, slices.Equal[[]int]) {
		t.Errorf("%s: links differ from a full rebuild's", label)
	}
}

// A rebuild on top of stored lists asks only for changes (since the last
// complete fetch) and for follows it has no list for, and still saves the
// same graph a full download of the same lists would.
func TestIncrementalRebuildMatchesAFullOne(t *testing.T) {
	owner, a, b, c, d := newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t)
	x, y, z, w := newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t)
	old := nostr.Now() - 3600*48
	relay := newLiveRelay(t,
		a.listAt(t, old, x, y, z, b),
		b.listAt(t, old, x, y),
		c.listAt(t, old, x, z),
		d.listAt(t, old, w, z),
	)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	ownerList := owner.followList(t, a, b, c)
	path := filepath.Join(t.TempDir(), "wot_cache.json")
	wt := NewSimpleInMemory(nostr.NewSimplePool(ctx), map[string]struct{}{owner.pk: {}},
		urls(relay), 3, 2, 5, path, 60)
	wt.LocalFollowLists = func() []*nostr.Event { return []*nostr.Event{ownerList} }
	wt.Refresh(ctx)
	if !wt.Has(ctx, x.pk) || wt.Has(ctx, w.pk) {
		t.Fatal("first build: want x in and w out")
	}
	if _, _, _, ok := wt.loadLists(); !ok {
		t.Fatal("a complete build did not store its lists")
	}

	// b's list changes (drops y, adds w), the owner follows d and unfollows c.
	relay.put(b.followList(t, x, w))
	time.Sleep(1100 * time.Millisecond)
	ownerList = owner.followList(t, a, b, d)
	relay.forget()
	wt.Refresh(ctx)

	var sinceAsked, fullAsked []string
	for _, f := range relay.asked() {
		if !slices.Contains(f.Kinds, nostr.KindFollowList) || slices.Contains(f.Authors, owner.pk) {
			continue
		}
		if f.Since != nil {
			sinceAsked = append(sinceAsked, f.Authors...)
		} else {
			fullAsked = append(fullAsked, f.Authors...)
		}
	}
	slices.Sort(sinceAsked)
	wantSince := []string{a.pk, b.pk}
	slices.Sort(wantSince)
	if !slices.Equal(fullAsked, []string{d.pk}) || !slices.Equal(sinceAsked, wantSince) {
		t.Fatalf("asked every list of %d follows and changes for %d; want every list of d only, changes for a and b", len(fullAsked), len(sinceAsked))
	}

	// The same lists, built from scratch.
	freshPath := filepath.Join(t.TempDir(), "wot_cache.json")
	fresh := NewSimpleInMemory(nostr.NewSimplePool(ctx), map[string]struct{}{owner.pk: {}},
		urls(relay), 3, 2, 5, freshPath, 60)
	fresh.LocalFollowLists = wt.LocalFollowLists
	fresh.Refresh(ctx)

	sameGraph(t, "after a change, a follow and an unfollow", readGraph(t, path), readGraph(t, freshPath))
	if wt.Has(ctx, y.pk) || !wt.Has(ctx, w.pk) || !wt.Has(ctx, z.pk) {
		t.Error("want y out (b dropped them), w in (b and d), z in (a and d)")
	}
}

// When no relay can be reached, an incremental rebuild keeps the web from
// the stored lists and does not move its since stamp, so the changes it
// missed are asked for again next time.
func TestIncrementalRebuildOfflineKeepsTheWebAndTheWindow(t *testing.T) {
	owner, a, b, x := newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t)
	relay := newLiveRelay(t, a.followList(t, x), b.followList(t, x))
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	ownerList := owner.followList(t, a, b)
	path := filepath.Join(t.TempDir(), "wot_cache.json")
	wt := NewSimpleInMemory(nostr.NewSimplePool(ctx), map[string]struct{}{owner.pk: {}},
		urls(relay), 3, 2, 5, path, 60)
	wt.LocalFollowLists = func() []*nostr.Event { return []*nostr.Event{ownerList} }
	wt.Refresh(ctx)
	before := readGraph(t, path)
	_, since, _, _ := wt.loadLists()

	wt.SeedRelays = []string{"ws://127.0.0.1:1"}
	time.Sleep(1100 * time.Millisecond)
	wt.Refresh(ctx)

	sameGraph(t, "offline", readGraph(t, path), before)
	if _, after, _, ok := wt.loadLists(); !ok || after != since {
		t.Errorf("offline rebuild moved the since stamp %d -> %d (ok %v)", since, after, ok)
	}
}

// A full pass that wasn't complete leaves the next one full: its stored
// lists may be missing some, and asking only for changes would never fill
// them in.
func TestIncompleteFullPassStaysFull(t *testing.T) {
	owner, a, x := newTestKey(t), newTestKey(t), newTestKey(t)
	relay := newLiveRelay(t, a.followList(t, x))
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	ownerList := owner.followList(t, a)
	wt := NewSimpleInMemory(nostr.NewSimplePool(ctx), map[string]struct{}{owner.pk: {}},
		urls(relay), 3, 1, 1, filepath.Join(t.TempDir(), "wot_cache.json"), 60)
	wt.LocalFollowLists = func() []*nostr.Event { return []*nostr.Event{ownerList} }
	wt.Refresh(ctx)
	lists, since, _, ok := wt.loadLists()
	if !ok || since == 0 {
		t.Fatalf("a complete first pass stored since %d (ok %v)", since, ok)
	}

	// A week on, the next pass is a full one, and one seed never answers.
	wt.saveLists(lists, since, time.Now().Add(-fullListsEvery-time.Hour).Unix())
	stuck := newLiveRelay(t)
	stuck.hang = true
	wt.SeedRelays = urls(relay, stuck)
	wt.Refresh(ctx)
	if !wt.Has(ctx, x.pk) {
		t.Fatal("x, from the relay that answered, is missing")
	}
	if _, since, _, ok := wt.loadLists(); !ok || since != 0 {
		t.Errorf("incomplete full pass stored since %d (ok %v); want 0 so the next pass is full", since, ok)
	}
}

// On a slow link every relay is slow: when the quorum itself took longer
// than listGrace, the others get as long again, not a fixed 1.5 s.
func TestListFetchGraceGrowsWithASlowQuorum(t *testing.T) {
	a, b, x := newTestKey(t), newTestKey(t), newTestKey(t)
	var quorum []*liveRelay
	for range listQuorum {
		r := newLiveRelay(t, a.followList(t, x))
		r.delay = 2 * time.Second
		quorum = append(quorum, r)
	}
	slow := newLiveRelay(t, b.followList(t, x))
	slow.delay = 3800 * time.Millisecond // after quorum + listGrace, inside quorum + quorum time

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	got := fetchLatestLists(ctx, nostr.NewSimplePool(ctx), urls(append(quorum, slow)...),
		nostr.Filter{Kinds: []int{nostr.KindFollowList}, Authors: []string{a.pk, b.pk}})
	if got.lists[b.pk] == nil {
		t.Error("the slow relay's list, sent within the quorum's own time after it, was dropped")
	}
}

// A relay that accepts the TCP connection but never finishes the websocket
// handshake must not hold the fetch: EnsureRelay waits up to 15 s on it.
func TestListFetchDoesNotWaitForAStuckConnect(t *testing.T) {
	a, x := newTestKey(t), newTestKey(t)
	var good []*liveRelay
	for range listQuorum {
		good = append(good, newLiveRelay(t, a.followList(t, x)))
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	var held []net.Conn
	var heldMu sync.Mutex
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			heldMu.Lock()
			held = append(held, c) // never answer the handshake
			heldMu.Unlock()
		}
	}()
	t.Cleanup(func() {
		heldMu.Lock()
		defer heldMu.Unlock()
		for _, c := range held {
			c.Close()
		}
	})

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	start := time.Now()
	got := fetchLatestLists(ctx, nostr.NewSimplePool(ctx), append(urls(good...), "ws://"+ln.Addr().String()),
		nostr.Filter{Kinds: []int{nostr.KindFollowList}, Authors: []string{a.pk}})
	if took := time.Since(start); took > listGrace+3*time.Second {
		t.Fatalf("fetch took %v waiting on a relay stuck connecting", took)
	}
	if !got.complete || got.lists[a.pk] == nil {
		t.Errorf("complete %v, list %v: the three good relays answered", got.complete, got.lists[a.pk] != nil)
	}
}
