package wot

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// Unfollowing everyone who brought someone into the web takes them out of it
// at the next rebuild, even when the seed relays still hold the list from
// before the unfollow: the list stored on this relay is newer and wins.
func TestUnfollowShrinksTheWebFromTheLocalList(t *testing.T) {
	owner, a, b, x := newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	before := owner.followList(t, a, b)
	before.CreatedAt -= 60
	if err := before.Sign(owner.sk); err != nil {
		t.Fatal(err)
	}
	// a and b both follow x; the seeds never see the owner's unfollow.
	relays := []string{seedRelay(t, before, a.followList(t, x), b.followList(t, x))}
	wt := NewSimpleInMemory(nostr.NewSimplePool(ctx), map[string]struct{}{owner.pk: {}},
		relays, 3, 2, 2, filepath.Join(t.TempDir(), "wot_cache.json"), 60)

	wt.Refresh(ctx)
	if !wt.Has(ctx, x.pk) {
		t.Fatal("x, followed by two of the owner's follows, is not in the web")
	}

	after := owner.followList(t)
	wt.LocalFollowLists = func() []*nostr.Event { return []*nostr.Event{after} }
	wt.Refresh(ctx)
	for name, k := range map[string]testKey{"a": a, "b": b, "x": x} {
		if wt.Has(ctx, k.pk) {
			t.Errorf("%s is still in the web after the owner unfollowed a and b", name)
		}
	}
	if !wt.Has(ctx, owner.pk) {
		t.Error("the owner left their own web")
	}
}

// A follow list newer than the graph rebuilds it once it settles, once per
// list; an older list, an unbuilt graph and an owner-only graph do not.
func TestFollowListNewerThanTheGraphRebuildsIt(t *testing.T) {
	owners := map[string]struct{}{"owner": {}}
	built := time.Unix(1_000_000, 0)
	graph := NewSimpleInMemory(nil, owners, nil, 3, 1, 1, "", 60)
	graph.pubkeys.Store(&map[string]bool{"owner": true, "friend": true})
	graph.builtAt.Store(built.Unix())

	var d followListDue
	listAt := built.Add(10 * time.Minute)
	if d.check(graph, built.Add(-time.Minute), listAt.Add(time.Hour)) {
		t.Fatal("a list older than the graph rebuilt it")
	}
	if d.check(graph, listAt, listAt.Add(FollowListSettle/2)) {
		t.Fatal("rebuilt before the list settled")
	}
	if !d.check(graph, listAt, listAt.Add(FollowListSettle)) {
		t.Fatal("an unfollow newer than the graph did not rebuild it")
	}
	if d.check(graph, listAt, listAt.Add(FollowListSettle+FollowListCheckInterval)) {
		t.Fatal("a rebuild that did not save was retried on the next tick")
	}
	if !d.check(graph, listAt, listAt.Add(FollowListSettle+EmptyGraphFallback)) {
		t.Fatal("a rebuild that did not save was never retried")
	}
	graph.builtAt.Store(listAt.Unix() + 1)
	if d.check(graph, listAt, listAt.Add(2*EmptyGraphFallback)) {
		t.Fatal("rebuilt a graph that already has the list")
	}

	unbuilt := NewSimpleInMemory(nil, owners, nil, 3, 1, 1, "", 60)
	if (&followListDue{}).check(unbuilt, listAt, listAt.Add(time.Hour)) {
		t.Fatal("rebuilt a graph that was never built")
	}
	empty := NewSimpleInMemory(nil, owners, nil, 3, 1, 1, "", 60)
	empty.pubkeys.Store(&map[string]bool{"owner": true})
	empty.builtAt.Store(built.Unix())
	if (&followListDue{}).check(empty, listAt, listAt.Add(time.Hour)) {
		t.Fatal("an owner-only graph is RefreshWhileEmpty's, not this watcher's")
	}
}

// A saved rebuild is stamped with when it started, so a list published while
// it ran still reads as newer than the graph; the cache keeps that stamp.
func TestRebuildIsStampedWithItsStart(t *testing.T) {
	owner, a := newTestKey(t), newTestKey(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	path := filepath.Join(t.TempDir(), "wot_cache.json")
	wt := NewSimpleInMemory(nostr.NewSimplePool(ctx), map[string]struct{}{owner.pk: {}},
		[]string{seedRelay(t, owner.followList(t, a))}, 2, 1, 2, path, 60)
	start := time.Now().Unix()
	wt.Refresh(ctx)
	if got := wt.BuiltAt().Unix(); got < start || got > time.Now().Unix() {
		t.Fatalf("built at %d, want the rebuild's start (%d or just after)", got, start)
	}
	loaded := NewSimpleInMemory(nil, nil, nil, 2, 1, 1, path, 60)
	if ok, _ := loaded.LoadFromCache(); !ok || !loaded.BuiltAt().Equal(wt.BuiltAt()) {
		t.Fatalf("cache loaded=%v built at %v, want %v", ok, loaded.BuiltAt(), wt.BuiltAt())
	}
}
