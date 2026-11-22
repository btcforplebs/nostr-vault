package trustrank

import (
	"context"
	"encoding/json"
	"os"
	"testing"
)

// deepCrawler runs with the real ceiling, so the depth rule decides.
func deepCrawler(t *testing.T, n *fakeNet, dir string) *Crawler {
	t.Helper()
	c := crawler(t, n, dir)
	c.Params = DefaultParams()
	return c
}

func list(follows ...string) List { return List{FollowsAt: 1, MutesAt: 1, Follows: follows} }

// wideNet: me follows `friends` people, who all follow one person in ring 2
// (pk 1000), who follows ring3 people (pk 2000+i). Every ring-3 person
// follows pk 3000 (ring 4), who follows pk 4000 (ring 5).
func wideNet(friends, ring3 int) *fakeNet {
	n := &fakeNet{lists: map[string]List{}}
	var fs []string
	for i := 0; i < friends; i++ {
		fs = append(fs, pk(100+i))
		n.lists[pk(100+i)] = list(pk(1000))
	}
	n.lists[pk(0)] = list(fs...)
	var r3 []string
	for i := 0; i < ring3; i++ {
		r3 = append(r3, pk(2000+i))
		n.lists[pk(2000+i)] = list(pk(3000))
	}
	n.lists[pk(1000)] = list(r3...)
	n.lists[pk(3000)] = list(pk(4000))
	return n
}

func resultFile(t *testing.T, dir string) ResultFile {
	t.Helper()
	b, err := os.ReadFile(ResultPath(dir, pk(0)))
	if err != nil {
		t.Fatal(err)
	}
	var rf ResultFile
	if err := json.Unmarshal(b, &rf); err != nil {
		t.Fatal(err)
	}
	return rf
}

// Ring 3 adds 1 person to 151 nearer ones (under 1%): its lists are not
// read and nobody past ring 3 is in the map.
func TestDepthStopsWhenARingAddsUnderOnePercent(t *testing.T) {
	n := wideNet(150, 1)
	dir := t.TempDir()
	res, err := deepCrawler(t, n, dir).RunPass(context.Background(), false)
	if err != nil {
		t.Fatal(err)
	}
	if n.called(pk(2000)) {
		t.Fatal("a ring that adds under 1% must not have its lists read")
	}
	if _, hop, ok := res.Score(pk(2000)); !ok || hop != 3 {
		t.Fatal("ring 3 itself is still ranked")
	}
	if rf := resultFile(t, dir); rf.MaxHop != 3 || rf.Params.MaxHop != 3 {
		t.Fatalf("the file says how far the pass reached: %d %d", rf.MaxHop, rf.Params.MaxHop)
	}
	if st := LoadState(dir, pk(0)); st.FullAt == 0 || st.Hop != 1 {
		t.Fatalf("a walk the rule ended is a finished pass: %+v", st)
	}
}

// Ring 3 adds 2 people to 151 (over 1%): the walk goes on. Ring 4 is one
// person against 153, so it is found and ranked but its list is not read.
func TestDepthWalksOnWhileARingAddsOnePercent(t *testing.T) {
	n := wideNet(150, 2)
	dir := t.TempDir()
	res, err := deepCrawler(t, n, dir).RunPass(context.Background(), false)
	if err != nil {
		t.Fatal(err)
	}
	if !n.called(pk(2000)) || !n.called(pk(2001)) {
		t.Fatal("ring 3 added over 1%: its lists must be read")
	}
	if _, hop, ok := res.Score(pk(3000)); !ok || hop != 4 {
		t.Fatal("ring 4 must be ranked")
	}
	if n.called(pk(3000)) {
		t.Fatal("ring 4 added under 1%: its list must not be read")
	}
	if _, _, ok := res.Score(pk(4000)); ok {
		t.Fatal("ring 5 must not be in the map")
	}
	if rf := resultFile(t, dir); rf.MaxHop != 4 {
		t.Fatalf("file maxHop %d", rf.MaxHop)
	}
}

// chainNet: one person per ring, out to ring `rings`. Every ring adds far
// more than 1%, so only the ceiling can stop the walk.
func chainNet(rings int) *fakeNet {
	n := &fakeNet{lists: map[string]List{}}
	for i := 0; i < rings; i++ {
		n.lists[pk(i)] = list(pk(i + 1))
	}
	return n
}

func TestDepthNeverPassesTheCeiling(t *testing.T) {
	n := chainNet(9)
	dir := t.TempDir()
	res, err := deepCrawler(t, n, dir).RunPass(context.Background(), false)
	if err != nil {
		t.Fatal(err)
	}
	if !n.called(pk(CeilingHop - 1)) {
		t.Fatal("ring 5's list must be read to find ring 6")
	}
	if n.called(pk(CeilingHop)) {
		t.Fatal("ring 6's list must never be read")
	}
	if _, hop, ok := res.Score(pk(CeilingHop)); !ok || hop != CeilingHop {
		t.Fatal("ring 6 must be ranked")
	}
	if _, _, ok := res.Score(pk(CeilingHop + 1)); ok {
		t.Fatal("ring 7 must not be in the map")
	}
	if rf := resultFile(t, dir); rf.MaxHop != CeilingHop {
		t.Fatalf("file maxHop %d", rf.MaxHop)
	}
}

// Past ring 2 the outer bar (shown scale) decides whose list is read, and
// it is also the bar the gain is counted against.
func TestDepthOuterBarDecidesPastRing2(t *testing.T) {
	// Ring 2: six people every friend follows. Ring 3: "liked" (all six
	// follow) and "lone" (one follows).
	liked, lone := pk(2000), pk(2001)
	var ring2 []string
	for i := 0; i < 6; i++ {
		ring2 = append(ring2, pk(1000+i))
	}
	thin := ring2[0] // the one who also follows lone
	build := func() *fakeNet {
		n := &fakeNet{lists: map[string]List{}}
		var fs []string
		for i := 0; i < 5; i++ {
			fs = append(fs, pk(100+i))
			n.lists[pk(100+i)] = list(ring2...)
		}
		n.lists[pk(0)] = list(fs...)
		for _, r := range ring2 {
			n.lists[r] = list(liked)
		}
		n.lists[thin] = list(liked, lone)
		n.lists[liked] = list(pk(3000))
		n.lists[lone] = list(pk(3001))
		return n
	}
	res, err := deepCrawler(t, build(), t.TempDir()).RunPass(context.Background(), false)
	if err != nil {
		t.Fatal(err)
	}
	a, _, _ := res.Score(liked)
	b, _, _ := res.Score(lone)
	if !(ShownRounded(a) > ShownRounded(b) && b > 0) {
		t.Fatalf("liked %.4f (%.1f) lone %.4f (%.1f)", a, ShownRounded(a), b, ShownRounded(b))
	}

	n := build()
	c := deepCrawler(t, n, t.TempDir())
	c.OuterBar = (ShownRounded(a) + ShownRounded(b)) / 2
	res, err = c.RunPass(context.Background(), false)
	if err != nil {
		t.Fatal(err)
	}
	if !n.called(liked) || n.called(lone) {
		t.Fatalf("past ring 2 only people over the outer bar are read: %v", n.calls)
	}
	if _, _, ok := res.Score(pk(3000)); !ok {
		t.Fatal("ring 4 behind a read list must be ranked")
	}
	if _, _, ok := res.Score(pk(3001)); ok {
		t.Fatal("ring 4 behind an unread list must not be in the map")
	}
}

// A deeper earlier pass leaves ring 3's lists in the store. When ring 3 no
// longer earns the walk, the people those old lists point at are gone from
// the result.
func TestDepthShrinksWhenARingStopsEarningIt(t *testing.T) {
	n := wideNet(150, 2)
	dir := t.TempDir()
	c := deepCrawler(t, n, dir)
	if res, err := c.RunPass(context.Background(), false); err != nil {
		t.Fatal(err)
	} else if _, _, ok := res.Score(pk(3000)); !ok {
		t.Fatal("first pass must reach ring 4")
	}
	n.lists[pk(1000)] = List{FollowsAt: 5, MutesAt: 5, Follows: []string{pk(2000)}}
	n.calls = nil
	res, err := c.RunPass(context.Background(), false)
	if err != nil {
		t.Fatal(err)
	}
	if n.called(pk(2000)) {
		t.Fatal("ring 3 now adds under 1%: its list must not be read again")
	}
	if _, _, ok := res.Score(pk(3000)); ok {
		t.Fatal("a ring this pass did not walk to must not come back from old lists")
	}
	if rf := resultFile(t, dir); rf.MaxHop != 3 {
		t.Fatalf("file maxHop %d", rf.MaxHop)
	}
}

// A pause in the middle of hop 4 goes on with hop 4: the rule is not asked
// again for a hop already under way.
func TestDepthResumeGoesOnWithAHopUnderWay(t *testing.T) {
	n := wideNet(150, 2)
	dir := t.TempDir()
	c := deepCrawler(t, n, dir)
	allowed := 1 + 150 + 1 + 1 // owner, friends, ring 2, then one of ring 3
	c.Wait = func(context.Context) bool { allowed--; return allowed >= 0 }
	if _, err := c.RunPass(context.Background(), false); err != ErrStopped {
		t.Fatalf("want ErrStopped, got %v", err)
	}
	if st := LoadState(dir, pk(0)); st.Hop != 4 || st.Last != pk(2000) {
		t.Fatalf("checkpoint %+v", st)
	}
	before := len(n.calls)
	c.Wait = func(context.Context) bool { return true }
	if _, err := c.RunPass(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	if got := n.calls[before:]; len(got) != 1 || got[0] != pk(2001) {
		t.Fatalf("resume must read the rest of ring 3 and stop: %v", got)
	}
}

// Rings 1 and 2 answer to Bar only: an outer bar nobody can pass still
// leaves ring 3 found and ranked, and ends the walk there.
func TestDepthOuterBarDoesNotTouchTheSureRings(t *testing.T) {
	n := wideNet(5, 3)
	c := deepCrawler(t, n, t.TempDir())
	c.OuterBar = 101
	res, err := c.RunPass(context.Background(), false)
	if err != nil {
		t.Fatal(err)
	}
	if !n.called(pk(1000)) {
		t.Fatal("ring 2's list is read whatever the outer bar is")
	}
	if _, hop, ok := res.Score(pk(2000)); !ok || hop != 3 {
		t.Fatal("ring 3 must be ranked")
	}
	if n.called(pk(2000)) {
		t.Fatal("nobody in ring 3 is over the outer bar: no ring-3 list is read")
	}
}

// New with the deeper walk, and pinned here on purpose (Tron, #2406): ring
// 3's lists are now read, so ring 3's mutes count against people nearer in.
// X is in ring 2. 200 ring-3 people, each vouched for by 60 ring-2 hubs,
// mute X. With the walk held at ring 3 (as before the depth rule) nobody
// reads those mutes and X stays over the view bar; with the real ceiling X
// drops under it. Whether far mutes should reach this far in is Logen's
// call; a change either way must change this test.
func TestDepthFarMutesLowerANearScore(t *testing.T) {
	x := pk(999)
	build := func() *fakeNet {
		n := &fakeNet{lists: map[string]List{}}
		hubs := []string{x}
		for i := 0; i < 60; i++ {
			hubs = append(hubs, pk(1000+i))
		}
		var friends []string
		for i := 0; i < 5; i++ {
			friends = append(friends, pk(100+i))
			n.lists[pk(100+i)] = list(hubs...)
		}
		n.lists[pk(0)] = list(friends...)
		var ring3 []string
		for i := 0; i < 200; i++ {
			ring3 = append(ring3, pk(2000+i))
			n.lists[pk(2000+i)] = List{FollowsAt: 1, MutesAt: 1, Mutes: []string{x}}
		}
		for _, h := range hubs[1:] {
			n.lists[h] = list(ring3...)
		}
		return n
	}
	shown := func(ceiling int) (float64, *fakeNet) {
		n := build()
		c := deepCrawler(t, n, t.TempDir())
		c.Params.MaxHop = ceiling
		res, err := c.RunPass(context.Background(), false)
		if err != nil {
			t.Fatal(err)
		}
		s, hop, ok := res.Score(x)
		if !ok || hop != 2 {
			t.Fatalf("X must be in ring 2: hop %d ok %v", hop, ok)
		}
		return ShownRounded(s), n
	}
	before, n3 := shown(SureHop)
	after, n6 := shown(CeilingHop)
	if n3.called(pk(2000)) || !n6.called(pk(2000)) {
		t.Fatal("ring 3's lists are read only by the deeper walk")
	}
	if !(before >= DefaultViewBar && after < DefaultViewBar) {
		t.Fatalf("X shows %.1f with the walk held at ring 3 and %.1f with the deeper walk; want over and under %.0f",
			before, after, DefaultViewBar)
	}
}
