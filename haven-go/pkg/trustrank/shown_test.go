package trustrank

import (
	"encoding/json"
	"math"
	"os"
	"testing"
)

func near(a, b float64) bool { return math.Abs(a-b) < 0.05 }

func TestShownScaleAnchorsAndBands(t *testing.T) {
	for _, c := range []struct{ rank, shown float64 }{
		{0, 0}, {0.01, 0}, {0.2, 20}, {30, 100}, {96, 100},
	} {
		if got := Shown(c.rank); !near(got, c.shown) {
			t.Errorf("Shown(%v) = %.2f, want %v", c.rank, got, c.shown)
		}
	}
	// The measured bands land where the scale promises (§10).
	for _, c := range []struct{ rank, lo, hi float64 }{
		{1, 44, 47}, {2, 55, 58}, {5, 69, 72}, {15, 85, 89}, {29, 99, 100},
	} {
		if s := Shown(c.rank); s < c.lo || s > c.hi {
			t.Errorf("Shown(%v) = %.2f, want %v-%v", c.rank, s, c.lo, c.hi)
		}
	}
}

func TestShownKeepsOrderAndInverts(t *testing.T) {
	prev := -1.0
	for r := 0.01; r < 120; r *= 1.07 {
		s := Shown(r)
		if s < prev {
			t.Fatalf("order broken at %v", r)
		}
		prev = s
		if s > 0 && s < 100 && !near(Shown(RankFor(s)), s) {
			t.Fatalf("RankFor does not invert Shown at %v", r)
		}
	}
	if RankFor(0) != 0 {
		t.Fatal("bar 0 lets everyone in the map through")
	}
}

func TestPassesShownUsesTheSliderScale(t *testing.T) {
	r := mustRank(t, base(), "me", nil)
	n, _, _ := r.Score("niche")
	s := Shown(n)
	if !r.PassesShown("niche", s-0.5) || r.PassesShown("niche", s+0.5) {
		t.Fatalf("niche rank %.3f shown %.2f", n, s)
	}
	if !r.PassesShown("f0", 100) {
		t.Fatal("the owner's follows always pass")
	}
}

func TestResultFileCarriesShownScores(t *testing.T) {
	n := net()
	dir := t.TempDir()
	res, err := crawler(t, n, dir).RunPass(t.Context(), false)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(ResultPath(dir, pk(0)))
	var rf ResultFile
	if err := json.Unmarshal(b, &rf); err != nil || rf.Version != 2 || rf.ViewBar != DefaultViewBar {
		t.Fatalf("%v %+v", err, rf)
	}
	for _, row := range rf.People {
		raw, _, _ := res.Score(row[0].(string))
		if !near(row[1].(float64), math.Round(Shown(raw)*10)/10) {
			t.Fatalf("%v: file %v, shown %v", row[0], row[1], Shown(raw))
		}
	}
}
