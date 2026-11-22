package trustrank

import (
	"fmt"
	"math"
	"testing"
)

func mustRank(t *testing.T, g *Graph, owner string, blocks []string) *Result {
	t.Helper()
	r, err := Rank(g, owner, blocks, DefaultParams())
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func score(t *testing.T, r *Result, pk string) float64 {
	t.Helper()
	s, _, ok := r.Score(pk)
	if !ok {
		t.Fatalf("%s is not in the map", pk)
	}
	return s
}

// The owner follows 10 friends; each friend follows the next layer.
func base() *Graph {
	g := NewGraph()
	var friends []string
	for i := 0; i < 10; i++ {
		friends = append(friends, fmt.Sprintf("f%d", i))
	}
	g.SetList("me", friends, nil)
	for i, f := range friends {
		// Everyone follows "popular"; 2 follow "niche".
		fs := []string{"popular"}
		if i < 2 {
			fs = append(fs, "niche")
		}
		g.SetList(f, fs, nil)
	}
	return g
}

func TestHopIsTrueFollowDistance(t *testing.T) {
	g := base()
	g.SetList("popular", []string{"far"}, nil)
	g.SetList("far", []string{"tooFar"}, nil)
	r := mustRank(t, g, "me", nil)
	for pk, want := range map[string]int{"f0": 1, "popular": 2, "far": 3} {
		if _, hop, ok := r.Score(pk); !ok || hop != want {
			t.Errorf("%s: hop %d ok %v, want %d", pk, hop, ok, want)
		}
	}
	if _, _, ok := r.Score("tooFar"); ok {
		t.Error("hop 4 must be left out of the map")
	}
}

func TestMoreTrustedVouchesScoreHigher(t *testing.T) {
	r := mustRank(t, base(), "me", nil)
	pop, niche := score(t, r, "popular"), score(t, r, "niche")
	if !(pop > niche && niche > 0) {
		t.Fatalf("popular %.3f niche %.3f", pop, niche)
	}
	for _, p := range r.People() {
		if p.Score < 0 || p.Score > 100 || math.IsNaN(p.Score) {
			t.Fatalf("%s scored %v", p.Pubkey, p.Score)
		}
	}
}

// Fake accounts following each other gain nothing: only a trusted person's
// follow lets one in, and the rest of the ring never enters the map's trust.
func TestSybilRingGainsNothing(t *testing.T) {
	g := base()
	var ring []string
	for i := 0; i < 50; i++ {
		ring = append(ring, fmt.Sprintf("sybil%d", i))
	}
	for _, s := range ring {
		g.SetList(s, append(append([]string{}, ring...), "spam"), nil)
	}
	// One friend follows one sybil.
	g.SetList("f9", []string{"popular", "sybil0"}, nil)
	r := mustRank(t, g, "me", nil)
	if s := score(t, r, "sybil0"); s >= score(t, r, "niche") {
		t.Fatalf("one trusted follow (%.3f) must not beat two (%.3f)", s, score(t, r, "niche"))
	}
	// 50 sybils vouching for "spam" (hop 3) count for less than one real friend's follow.
	g2 := base()
	g2.SetList("f0", []string{"popular", "niche", "real"}, nil)
	r2 := mustRank(t, g2, "me", nil)
	if spam, real := score(t, r, "spam"), score(t, r2, "real"); spam >= real {
		t.Fatalf("spam %.4f vouched by a 50-sybil ring must score under real %.4f vouched by one friend", spam, real)
	}
	// Nobody trusted follows the ring at all: none of it is in the map.
	g3 := base()
	for _, s := range ring {
		g3.SetList(s, ring, nil)
	}
	r3 := mustRank(t, g3, "me", nil)
	if _, _, ok := r3.Score("sybil1"); ok {
		t.Fatal("an unconnected ring must not appear")
	}
}

func TestTrustedMutesLowerAScore(t *testing.T) {
	g := base()
	g.SetList("f9", []string{"popular"}, []string{"niche"})
	g.SetList("f8", []string{"popular", "twin"}, nil)
	g.SetList("f7", []string{"popular", "twin"}, nil)
	r := mustRank(t, g, "me", nil)
	if muted, twin := score(t, r, "niche"), score(t, r, "twin"); muted >= twin {
		t.Fatalf("followed by 2 and muted by 1 (%.3f) must score under followed by 2 (%.3f)", muted, twin)
	}
	why := r.Explain("niche", 0)
	var sawMute bool
	for _, w := range why {
		if w.Rater == "f9" && w.Muted {
			sawMute = true
		}
	}
	if !sawMute || len(why) != 3 {
		t.Fatalf("why? must name both followers and the muter: %+v", why)
	}
}

func TestOwnerMutesAlwaysWin(t *testing.T) {
	g := base()
	g.SetList("f0", []string{"popular", "niche", "onlyViaF0"}, nil)
	r := mustRank(t, g, "me", []string{"f0", "popular"})
	if s := score(t, r, "popular"); s != 0 || r.Passes("popular", 0) {
		t.Fatalf("an owner-muted person scores 0 and never passes, got %.3f", s)
	}
	if r.Passes("f0", 0) {
		t.Fatal("an owner-muted follow never passes")
	}
	if s, _, ok := r.Score("onlyViaF0"); ok && s != 0 {
		t.Fatalf("an owner-muted person's follows count for nothing, got %.3f", s)
	}
	// The owner's own mute list counts the same as the blocks passed in.
	g.SetList("me", []string{"f0", "f1", "f2"}, []string{"niche"})
	r = mustRank(t, g, "me", nil)
	if r.Passes("niche", 0) {
		t.Fatal("a person on the owner's mute list never passes")
	}
}

func TestBarGatesStrangersNotFollows(t *testing.T) {
	r := mustRank(t, base(), "me", nil)
	if !r.Passes("f3", 100) {
		t.Fatal("the owner's own follows always pass")
	}
	n := score(t, r, "niche")
	if !r.Passes("niche", n) || r.Passes("niche", n+0.001) {
		t.Fatal("the bar is inclusive at the score")
	}
}

func TestStableAndConverged(t *testing.T) {
	g := base()
	a, b := mustRank(t, g, "me", nil), mustRank(t, g, "me", nil)
	pa, pb := a.People(), b.People()
	if len(pa) != len(pb) {
		t.Fatal("same input, different size")
	}
	for i := range pa {
		if pa[i] != pb[i] {
			t.Fatalf("row %d differs: %+v %+v", i, pa[i], pb[i])
		}
	}
	if a.Rounds >= a.Params.MaxRounds {
		t.Fatalf("did not converge in %d rounds", a.Rounds)
	}
}

func TestBadInput(t *testing.T) {
	if _, err := Rank(NewGraph(), "me", nil, DefaultParams()); err == nil {
		t.Fatal("no owner list must be an error")
	}
	p := DefaultParams()
	p.Rigor = 1
	if _, err := Rank(base(), "me", nil, p); err == nil {
		t.Fatal("rigor 1 must be refused")
	}
}

// A graph the size of Logen's d<=2 crawl (scaled down) ranks quickly.
func BenchmarkRank(b *testing.B) {
	g := NewGraph()
	var l1 []string
	for i := 0; i < 1000; i++ {
		l1 = append(l1, fmt.Sprintf("a%d", i))
	}
	g.SetList("me", l1, nil)
	for i, a := range l1 {
		var fs []string
		for j := 0; j < 300; j++ {
			fs = append(fs, fmt.Sprintf("b%d", (i*7+j*13)%40000))
		}
		g.SetList(a, fs, nil)
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := Rank(g, "me", nil, DefaultParams()); err != nil {
			b.Fatal(err)
		}
	}
}

// One trusted follow lets a ring in, but the ring cannot lift itself: no
// sybil scores above Attenuation times the attacker who vouches for it, and
// the attacker scores no more than anyone else that friend follows (Tron's
// #2370 setup: rings of 60+ used to climb to 72-99).
func TestSybilRingWithOneTrustedFollowStaysCapped(t *testing.T) {
	for _, n := range []int{40, 60, 100, 300} {
		g := NewGraph()
		g.SetList("me", []string{"friend", "f1"}, nil)
		fs := []string{"A"}
		for i := 0; i < 150; i++ {
			fs = append(fs, fmt.Sprintf("normal%d", i))
		}
		g.SetList("friend", fs, nil)
		var ring []string
		for i := 0; i < n; i++ {
			ring = append(ring, fmt.Sprintf("s%d", i))
		}
		g.SetList("A", ring, nil)
		for _, s := range ring {
			g.SetList(s, append(append([]string{}, ring...), "A"), nil)
		}
		r := mustRank(t, g, "me", nil)
		a := score(t, r, "A")
		capped := a*r.Params.Attenuation + 1e-9
		for _, s := range ring {
			if v := score(t, r, s); v > capped {
				t.Fatalf("ring %d: %s scored %.4f, above A %.4f x attenuation", n, s, v, a)
			}
		}
		if f1 := score(t, r, "f1"); a >= f1 || r.Passes("s0", 20) {
			t.Fatalf("ring %d: A %.4f must stay under a real follow %.4f and s0 must not pass 20", n, a, f1)
		}
		// The ring following A back adds nothing: A scores like any other
		// person friend follows.
		if norm := score(t, r, "normal0"); a != norm {
			t.Fatalf("ring %d: A %.4f must equal friend's normal follow %.4f", n, a, norm)
		}
		if r.Rounds >= r.Params.MaxRounds {
			t.Fatalf("ring %d: did not converge in %d rounds", n, r.Rounds)
		}
	}
}

// The owner seen only inside someone else's list is not the owner's list.
func TestOwnerOnlyInsideAnotherList(t *testing.T) {
	g := NewGraph()
	g.SetList("stranger", []string{"me"}, nil)
	if _, err := Rank(g, "me", nil, DefaultParams()); err == nil {
		t.Fatal("an owner with no list of their own must be an error")
	}
}

func TestMaxHopFitsInt8(t *testing.T) {
	p := DefaultParams()
	p.MaxHop = 200
	if _, err := Rank(base(), "me", nil, p); err == nil {
		t.Fatal("max hop over 127 must be refused")
	}
	p.MaxHop = 127
	if _, err := Rank(base(), "me", nil, p); err != nil {
		t.Fatal(err)
	}
}
