package trustrank

import (
	"context"
	"encoding/json"
	"reflect"
	"testing"
)

// ringNet: me follows ring 1 (20 people); everyone in ring h follows all of
// ring h+1 (20 people each, ring 5 has 5). ring(h, i) is ring h's i-th
// person. One ring-3 person mutes ring 2's first person: a list the feed
// walk never reads, so it must never lower that score.
func ringNet() (n *fakeNet, ring func(h, i int) string) {
	ring = func(h, i int) string { return pk(h*1000 + i) }
	size := map[int]int{1: 20, 2: 20, 3: 20, 4: 20, 5: 5}
	members := func(h int) []string {
		var out []string
		for i := 0; i < size[h]; i++ {
			out = append(out, ring(h, i))
		}
		return out
	}
	n = &fakeNet{lists: map[string]List{pk(0): list(members(1)...)}}
	for h := 1; h <= 4; h++ {
		for _, p := range members(h) {
			n.lists[p] = list(members(h + 1)...)
		}
	}
	for _, p := range members(5) {
		n.lists[p] = list(pk(9999)) // ring 6: never reached
	}
	l := n.lists[ring(3, 0)]
	l.Mutes = []string{ring(2, 0)}
	n.lists[ring(3, 0)] = l
	return n, ring
}

// globeCrawler: the real ceiling, and an outer bar nobody reaches, so the
// depth rule ends the feed walk at ring 3 (rings 1-3 are always walked).
func globeCrawler(t *testing.T, n *fakeNet, dir string) *Crawler {
	t.Helper()
	c := deepCrawler(t, n, dir)
	c.OuterBar = 101
	return c
}

// The globe step reads ring 3's and ring 4's lists, so the globe reaches
// ring 5, and stops there: ring 5's lists are never read.
func TestGlobeWalksToHop5(t *testing.T) {
	n, ring := ringNet()
	dir := t.TempDir()
	c := globeCrawler(t, n, dir)
	if _, err := c.RunPass(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	for _, h := range []int{3, 4} {
		if !n.called(ring(h, 0)) || !c.Store.GlobeOnly(ring(h, 0)) {
			t.Fatalf("ring %d's lists must be read, for the globe only", h)
		}
	}
	if n.called(ring(5, 0)) {
		t.Fatal("ring 5's lists are past GlobeHop: never read")
	}
	if c.Store.GlobeOnly(ring(2, 0)) || c.Store.GlobeOnly(pk(0)) {
		t.Fatal("lists the feed walk read are not globe-only")
	}
	rf := resultFile(t, dir)
	hops := map[int]int{}
	for _, r := range rf.Globe {
		hops[int(r[2].(float64))]++
	}
	if hops[4] == 0 || hops[5] == 0 {
		t.Fatalf("globe rows per hop %v: rings 4 and 5 must be there", hops)
	}
	for _, r := range rf.People {
		if r[2].(float64) > 3 {
			t.Fatalf("a feed row past ring 3: %v", r)
		}
	}
	if rf.MaxHop != 5 || rf.Params.MaxHop != 3 {
		t.Fatalf("maxHop %d (want 5, the globe's), params %d (want 3, the feed's)", rf.MaxHop, rf.Params.MaxHop)
	}
	// A device takes the copy: its globe rows are within maxHop.
	f, err := ReadResult(dir, pk(0))
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(f.Handoff(HandoffFloor))
	if _, err := CheckHandoff(raw, pk(0)); err != nil {
		t.Fatalf("a copy with ring-5 globe rows refused: %v", err)
	}
	if st := LoadState(dir, pk(0)); st.Globe != 0 || st.Hop != 1 || st.FullAt == 0 {
		t.Fatalf("a finished pass leaves no globe place: %+v", st)
	}
}

// Feed scores do not move with globe-only lists: `people` is exactly the
// rank of the lists the feed walk read (owner, rings 1 and 2), although a
// globe-only list mutes a ring-2 person.
func TestGlobeOnlyListsLeaveFeedScoresAlone(t *testing.T) {
	n, ring := ringNet()
	dir := t.TempDir()
	if _, err := globeCrawler(t, n, dir).RunPass(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	got := resultFile(t, dir).People

	feedOnly := func(withGlobe bool) [][3]any {
		g := NewGraph()
		for who, l := range n.lists {
			h := 0
			for hh := 1; hh <= 5; hh++ {
				for i := 0; i < 20; i++ {
					if ring(hh, i) == who {
						h = hh
					}
				}
			}
			if h <= 2 || (withGlobe && h <= 4) {
				g.SetList(who, l.Follows, l.Mutes)
			}
		}
		p := DefaultParams()
		p.MaxHop = 3
		res, err := Rank(g, pk(0), nil, p)
		if err != nil {
			t.Fatal(err)
		}
		var rows [][3]any
		for _, q := range res.People() {
			if s := ShownRounded(q.Score); s != 0 || q.Hop == 1 {
				rows = append(rows, [3]any{q.Pubkey, s, float64(q.Hop)})
			}
		}
		return rows
	}
	if want := feedOnly(false); !reflect.DeepEqual(got, want) {
		t.Fatalf("feed rows moved with globe-only lists:\n got %v\nwant %v", got[:3], want[:3])
	}
	// The control: counting the globe-only lists does move a feed score,
	// so the check above can fail.
	if reflect.DeepEqual(feedOnly(true), feedOnly(false)) {
		t.Fatal("the globe-only mute moves nothing, so this test proves nothing")
	}
}

// A later feed walk that reads a globe-only list drops its mark: it counts
// in the feed again.
func TestFeedReadDropsTheGlobeMark(t *testing.T) {
	n, ring := ringNet()
	dir := t.TempDir()
	c := globeCrawler(t, n, dir)
	if _, err := c.RunPass(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	if !c.Store.GlobeOnly(ring(3, 0)) {
		t.Fatal("setup: ring 3 is globe-only after the first pass")
	}
	c.OuterBar = 0 // now ring 3 earns the walk
	res, err := c.RunPass(context.Background(), false)
	if err != nil {
		t.Fatal(err)
	}
	if c.Store.GlobeOnly(ring(3, 0)) {
		t.Fatal("a list the feed walk read must lose its globe mark")
	}
	if _, hop, ok := res.Score(ring(4, 0)); !ok || hop != 4 {
		t.Fatal("the feed now ranks ring 4")
	}
}

// The marks are on disk: a store opened again still leaves them out.
func TestGlobeMarksSurviveReopen(t *testing.T) {
	dir := t.TempDir()
	s, err := OpenStore(dir, 0)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.MarkGlobe([]string{pk(1), pk(2), "not hex"}); err != nil {
		t.Fatal(err)
	}
	s.Put(pk(1), 1, []string{pk(3)}, nil)
	s.Put(pk(2), 1, []string{pk(3)}, nil)
	s.UnmarkGlobe([]string{pk(2)})
	s.Close()
	s, err = OpenStore(dir, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if !s.GlobeOnly(pk(1)) || s.GlobeOnly(pk(2)) || s.GlobeMarks() != 1 {
		t.Fatalf("marks after reopen: 1=%v 2=%v n=%d", s.GlobeOnly(pk(1)), s.GlobeOnly(pk(2)), s.GlobeMarks())
	}
	g, err := s.FeedGraph()
	if err != nil {
		t.Fatal(err)
	}
	if g.listed[g.index[pk(1)]] || !g.listed[g.index[pk(2)]] {
		t.Fatal("the feed graph must leave out exactly the marked lists")
	}
	if full, _ := s.Graph(); !full.listed[full.index[pk(1)]] {
		t.Fatal("the whole graph keeps every list")
	}
}

// A pause in the globe step resumes in the globe step: the feed walk is not
// read again and the globe step goes on after its last list.
func TestGlobeStepResumes(t *testing.T) {
	n, ring := ringNet()
	dir := t.TempDir()
	c := globeCrawler(t, n, dir)
	allowed := 1 + 20 + 20 + 5 // owner, rings 1 and 2, then 5 of ring 3
	c.Wait = func(context.Context) bool { allowed--; return allowed >= 0 }
	if _, err := c.RunPass(context.Background(), false); err != ErrStopped {
		t.Fatalf("want ErrStopped, got %v", err)
	}
	st := LoadState(dir, pk(0))
	if st.Globe != 3 || st.Last == "" || st.Hop != 4 {
		t.Fatalf("checkpoint inside the globe step: %+v", st)
	}
	n.calls = nil
	c.Wait = func(context.Context) bool { return true }
	if _, err := c.RunPass(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	if n.called(pk(0)) || n.called(ring(1, 0)) || n.called(ring(2, 0)) {
		t.Fatal("the resume read the feed walk again")
	}
	if n.called(st.Last) {
		t.Fatal("the resume read the last globe list again")
	}
	if !n.called(ring(4, 0)) {
		t.Fatal("the resume must finish the globe step")
	}
}
