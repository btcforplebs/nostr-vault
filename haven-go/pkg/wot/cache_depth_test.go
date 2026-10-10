package wot

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// The apps filter Global and Discovery against wot_cache.json, so every depth
// has to write it. Depths 1 and 2 used to return without saving; on Android
// (depth 2 by default) the file never existed and both feeds came up empty.
func TestRefreshWritesCacheAtEveryDepth(t *testing.T) {
	for _, depth := range []int{1, 2} {
		path := filepath.Join(t.TempDir(), "wot_cache.json")
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		wt := NewSimpleInMemory(nostr.NewSimplePool(ctx),
			map[string]struct{}{"owner": {}},
			nil, // no seed relays: depth 2 fetches nothing
			depth, 1, 1, path, 60)
		wt.Refresh(ctx)
		cancel()

		if _, err := os.Stat(path); err != nil {
			t.Fatalf("depth %d: no cache written: %v", depth, err)
		}
		reloaded := NewSimpleInMemory(nil, nil, nil, depth, 1, 1, path, 60)
		if ok, _ := reloaded.LoadFromCache(); !ok {
			t.Fatalf("depth %d: written cache does not load", depth)
		}
		if !reloaded.Has(context.Background(), "owner") {
			t.Errorf("depth %d: owner missing from the saved graph", depth)
		}
	}
}

// Changing the depth setting must not keep serving a graph built at the old
// depth until the TTL runs out.
func TestCacheFromAnotherDepthIsRebuilt(t *testing.T) {
	path := filepath.Join(t.TempDir(), "wot_cache.json")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	NewSimpleInMemory(nostr.NewSimplePool(ctx), map[string]struct{}{"owner": {}}, nil, 2, 1, 1, path, 60).Refresh(ctx)

	if ok, _ := NewSimpleInMemory(nil, nil, nil, 2, 1, 1, path, 60).LoadFromCache(); !ok {
		t.Fatal("same-depth cache did not load")
	}
	if ok, _ := NewSimpleInMemory(nil, nil, nil, 3, 1, 1, path, 60).LoadFromCache(); ok {
		t.Fatal("a depth-2 cache was served at depth 3")
	}
}

// A seed relay that never sends EOSE keeps FetchMany open until the timeout,
// which then closes the channel. What the healthy relays already sent must
// still be handed over: the collector's send loop also selected on the
// (now done) timeout context, so Go picked "done" at random and dropped most
// of the batch — one dead seed relay emptied the depth-3 pass.
func TestLatestEventsSurviveTimeout(t *testing.T) {
	const n = 50
	events := make(chan nostr.RelayEvent)
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	go func() {
		for i := 0; i < n; i++ {
			events <- nostr.RelayEvent{Event: &nostr.Event{Kind: 3, PubKey: fmt.Sprint(i), CreatedAt: 1}}
		}
		<-ctx.Done() // the slow relay: nothing more until the timeout
		close(events)
	}()
	var counter atomic.Int64
	got := 0
	for range latestEventByKindAndPubkey(ctx, events, &counter) {
		got++
	}
	if got != n {
		t.Fatalf("got %d of %d contact lists after the timeout", got, n)
	}
}

// A graph written by an older build (no version, or an older one) is rebuilt.
func TestCacheFromOlderBuildIsRebuilt(t *testing.T) {
	path := filepath.Join(t.TempDir(), "wot_cache.json")
	old := fmt.Sprintf(`{"pubkeys":{"owner":true},"timestamp":%d,"depth":3}`, time.Now().Unix())
	if err := os.WriteFile(path, []byte(old), 0644); err != nil {
		t.Fatal(err)
	}
	if ok, _ := NewSimpleInMemory(nil, nil, nil, 3, 1, 1, path, 60).LoadFromCache(); ok {
		t.Fatal("a cache without a version was served")
	}
}

// An owner who follows nobody has a graph of exactly themselves. Nothing the
// app or relay picks may stand in for follows the owner never made: the web of
// trust comes only from the people the owner follows.
func TestOwnerWhoFollowsNobodyGetsNoSeededGraph(t *testing.T) {
	for _, depth := range []int{2, 3} {
		path := filepath.Join(t.TempDir(), "wot_cache.json")
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		wt := NewSimpleInMemory(nostr.NewSimplePool(ctx),
			map[string]struct{}{"owner": {}},
			nil, // no seed relays: the owner's follow list is empty
			depth, 1, 1, path, 60)
		wt.Refresh(ctx)
		cancel()

		if got := wt.Size(); got != 1 || !wt.Has(context.Background(), "owner") {
			t.Fatalf("depth %d: graph holds %d pubkeys, want only the owner", depth, got)
		}
	}
}

type countingRefresher struct {
	onlyOwners bool
	refreshes  int
}

func (c *countingRefresher) NamesOnlyOwners() bool     { return c.onlyOwners }
func (c *countingRefresher) Refresh(_ context.Context) { c.refreshes++ }

// A new account's first follows must reach its graph in minutes: an empty
// graph is rebuilt on the short ticker, and a graph with people in it is left
// to the daily refresh.
func TestRefreshIfOnlyOwners(t *testing.T) {
	empty := &countingRefresher{onlyOwners: true}
	if !refreshIfOnlyOwners(context.Background(), empty) || empty.refreshes != 1 {
		t.Fatalf("an owner-only graph was not rebuilt (refreshes=%d)", empty.refreshes)
	}
	full := &countingRefresher{onlyOwners: false}
	if refreshIfOnlyOwners(context.Background(), full) || full.refreshes != 0 {
		t.Fatalf("a graph with people in it was rebuilt early (refreshes=%d)", full.refreshes)
	}
	if refreshIfOnlyOwners(context.Background(), nil) {
		t.Fatal("no instance reported a refresh")
	}
}

func TestNamesOnlyOwners(t *testing.T) {
	owners := map[string]struct{}{"owner": {}}
	graph := func(depth int, keys ...string) *SimpleInMemory {
		wt := NewSimpleInMemory(nil, owners, nil, depth, 1, 1, "", 60)
		m := map[string]bool{}
		for _, k := range keys {
			m[k] = true
		}
		wt.pubkeys.Store(&m)
		return wt
	}
	if !graph(3, "owner").NamesOnlyOwners() {
		t.Error("a graph of just the owner should be waiting for follows")
	}
	if graph(3, "owner", "friend").NamesOnlyOwners() {
		t.Error("a graph with a follow is not empty")
	}
	if graph(1, "owner").NamesOnlyOwners() {
		t.Error("depth 1 only ever holds the owner and must not refresh every 2 minutes")
	}
	if NewSimpleInMemory(nil, owners, nil, 3, 1, 1, "", 60).NamesOnlyOwners() {
		t.Error("a graph that was never built is not an empty graph")
	}
}

// A depth-3 cache from before the links file existed is rebuilt once, so the
// apps get their lines; a depth-2 build drops a links file it can't refresh.
func TestLinksFileFollowsTheDepth(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "wot_cache.json")
	links := filepath.Join(dir, linksFile)
	wt := NewSimpleInMemory(nil, map[string]struct{}{"owner": {}}, nil, 3, 1, 1, path, 60)
	wt.pubkeys.Store(&map[string]bool{"owner": true})
	wt.SaveCache()
	if ok, _ := wt.LoadFromCache(); ok {
		t.Fatal("a depth-3 cache without a links file was served")
	}
	wt.saveLinks([]string{"a"}, map[string][]int{"b": {0}})
	if ok, _ := wt.LoadFromCache(); !ok {
		t.Fatal("a depth-3 cache with its links file was not served")
	}
	if _, err := os.Stat(links + ".tmp"); !os.IsNotExist(err) {
		t.Error("the temporary links file was left behind")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	NewSimpleInMemory(nostr.NewSimplePool(ctx), map[string]struct{}{"owner": {}}, nil, 2, 1, 1, path, 60).Refresh(ctx)
	if _, err := os.Stat(links); !os.IsNotExist(err) {
		t.Error("a depth-2 build kept the depth-3 links file")
	}
}
