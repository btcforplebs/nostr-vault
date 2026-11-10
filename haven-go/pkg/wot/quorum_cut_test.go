package wot

import (
	"context"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// cutFixture is three fast seeds and one slow one (4 s, well past the
// quorum's grace), the shape where the quorum cuts the slow seed.
func cutFixture(t *testing.T) (fast []*liveRelay, slow *liveRelay) {
	for range listQuorum {
		fast = append(fast, newLiveRelay(t))
	}
	slow = newLiveRelay(t)
	slow.delay = 4 * time.Second
	return fast, slow
}

func newCutWot(ctx context.Context, t *testing.T, owner testKey, relays []*liveRelay, minFollowers, timeout int) (*SimpleInMemory, string) {
	path := filepath.Join(t.TempDir(), "wot_cache.json")
	return NewSimpleInMemory(nostr.NewSimplePool(ctx), map[string]struct{}{owner.pk: {}},
		urls(relays...), 3, minFollowers, timeout, path, 60), path
}

// The fetch names the relays it cut, so they can be asked again.
func TestListFetchReportsTheRelaysItCut(t *testing.T) {
	a, x := newTestKey(t), newTestKey(t)
	fast, slow := cutFixture(t)
	fast[0].put(a.followList(t, x))
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	got := fetchLatestLists(ctx, nostr.NewSimplePool(ctx), urls(append(fast, slow)...),
		nostr.Filter{Kinds: []int{nostr.KindFollowList}, Authors: []string{a.pk}})
	if !got.complete || !slices.Equal(got.cut, []string{slow.url}) || got.whole() {
		t.Fatalf("complete %v, cut %v, whole %v: want complete, the slow relay cut, not whole", got.complete, got.cut, got.whole())
	}
	all := fetchListsFromEvery(ctx, nostr.NewSimplePool(ctx), urls(append(fast, slow)...),
		nostr.Filter{Kinds: []int{nostr.KindFollowList}, Authors: []string{a.pk}})
	if !all.whole() {
		t.Fatalf("waiting for every relay: cut %v, complete %v; want whole", all.cut, all.complete)
	}
}

// MF2: a full build keeps a person whose second vouch is a list only the cut
// relay holds; the cut relay is asked again for the follows still missing.
func TestFullBuildAsksTheCutRelayAgain(t *testing.T) {
	owner, a, b, x := newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t)
	fast, slow := cutFixture(t)
	fast[0].put(a.followList(t, x))
	slow.put(b.followList(t, x))
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	wt, _ := newCutWot(ctx, t, owner, append(fast, slow), 2, 30)
	ownerList := owner.followList(t, a, b)
	wt.LocalFollowLists = func() []*nostr.Event { return []*nostr.Event{ownerList} }
	wt.Refresh(ctx)
	if !wt.Has(ctx, x.pk) {
		t.Fatal("x lost the vouch held only by the cut relay")
	}
	if _, since, fullAt, ok := wt.loadLists(); !ok || since == 0 || fullAt == 0 {
		t.Errorf("the cut relay answered when asked again, yet the pass stored since %d, full %d", since, fullAt)
	}
	// Only the follow still missing a list was asked again.
	var again [][]string
	for _, f := range slow.asked() {
		if !slices.Contains(f.Authors, owner.pk) {
			again = append(again, f.Authors)
		}
	}
	if len(again) != 2 || !slices.Equal(again[1], []string{b.pk}) {
		t.Errorf("slow relay was asked %v; want the batch, then b alone", again)
	}
}

// MF1: a change only the cut relay holds is found by the incremental pass,
// and since moves only once the cut relay has answered.
func TestIncrementalPassFindsAChangeOnTheCutRelay(t *testing.T) {
	owner, a, b, x, y := newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t)
	fast, slow := cutFixture(t)
	slow.delay = 0
	old := nostr.Now() - 3600*48
	for _, r := range append(fast, slow) {
		r.put(a.listAt(t, old, x, y), b.listAt(t, old, x))
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	wt, _ := newCutWot(ctx, t, owner, append(fast, slow), 2, 30)
	ownerList := owner.followList(t, a, b)
	wt.LocalFollowLists = func() []*nostr.Event { return []*nostr.Event{ownerList} }
	wt.Refresh(ctx)
	if !wt.Has(ctx, x.pk) || wt.Has(ctx, y.pk) {
		t.Fatal("first build: want x in (a and b), y out (a only)")
	}
	_, since, _, _ := wt.loadLists()

	// b now follows y too, and only the slow relay got it.
	time.Sleep(1100 * time.Millisecond)
	slow.put(b.followList(t, x, y))
	slow.delay = 4 * time.Second
	wt.Refresh(ctx)
	if !wt.Has(ctx, y.pk) {
		t.Fatal("y: b's change, held only by the cut relay, was never found")
	}
	if _, after, _, _ := wt.loadLists(); after <= since {
		t.Errorf("the cut relay answered when asked again; since should move, got %d -> %d", since, after)
	}
}

// MF1: when the cut relay still does not answer, since stays put, so the next
// pass asks the same window again.
func TestIncrementalPassKeepsTheWindowWhenTheCutRelayNeverAnswers(t *testing.T) {
	owner, a, b, x := newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t)
	fast, slow := cutFixture(t)
	slow.delay = 0
	for _, r := range append(fast, slow) {
		r.put(a.followList(t, x), b.followList(t, x))
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	wt, _ := newCutWot(ctx, t, owner, append(fast, slow), 2, 3)
	ownerList := owner.followList(t, a, b)
	wt.LocalFollowLists = func() []*nostr.Event { return []*nostr.Event{ownerList} }
	wt.Refresh(ctx)
	_, since, _, ok := wt.loadLists()
	if !ok || since == 0 {
		t.Fatalf("first build stored since %d (ok %v)", since, ok)
	}

	slow.hang = true
	time.Sleep(1100 * time.Millisecond)
	wt.Refresh(ctx)
	if !wt.Has(ctx, x.pk) {
		t.Fatal("x left the web on a pass that only cut a relay")
	}
	if _, after, _, ok := wt.loadLists(); !ok || after != since {
		t.Errorf("a pass whose cut relay never answered moved since %d -> %d (ok %v)", since, after, ok)
	}
}

// MF3: the owner's own list is never quorum-cut. A first build with the
// owner's list only on the slow relay must still find their follows.
func TestOwnerListIsNotQuorumCut(t *testing.T) {
	owner, a, x := newTestKey(t), newTestKey(t), newTestKey(t)
	fast, slow := cutFixture(t)
	slow.put(owner.followList(t, a))
	fast[0].put(a.followList(t, x))
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	wt, _ := newCutWot(ctx, t, owner, append(fast, slow), 1, 30)
	wt.Refresh(ctx)
	if !wt.Has(ctx, a.pk) || !wt.Has(ctx, x.pk) {
		t.Fatalf("first build: follow a %v, x %v; the owner's list on the slow relay was cut", wt.Has(ctx, a.pk), wt.Has(ctx, x.pk))
	}
}

// MF3: an owners' fetch that never finished does not stamp a full pass.
func TestOwnerFetchCutShortDoesNotStampAFullPass(t *testing.T) {
	owner, a, x := newTestKey(t), newTestKey(t), newTestKey(t)
	fast, slow := cutFixture(t)
	slow.hang = true
	fast[0].put(owner.followList(t, a), a.followList(t, x))
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	wt, _ := newCutWot(ctx, t, owner, append(fast, slow), 1, 2)
	wt.Refresh(ctx)
	if !wt.Has(ctx, x.pk) {
		t.Fatal("x, from the relays that answered, is missing")
	}
	if _, since, fullAt, _ := wt.loadLists(); since != 0 || fullAt != 0 {
		t.Errorf("owners' fetch was cut by the timeout, yet the pass stored since %d, full %d", since, fullAt)
	}
}
