package wot

import "testing"

func TestReachNamesFollowsAndCountsTheSecondLayer(t *testing.T) {
	wt := &SimpleInMemory{}
	if _, _, known := wt.Reach("x"); known {
		t.Fatal("no graph: reach must be unknown")
	}
	wt.layers.Store(&layers{follows: []string{"a", "c"}})
	if _, _, known := wt.Reach("x"); known {
		t.Fatal("depth 2 has no vouch counts: unknown")
	}
	wt.layers.Store(&layers{follows: []string{"a", "c"}, vouches: map[string]int{"x": 5, "y": 1, "z": 9}})
	if _, follow, known := wt.Reach("c"); !follow || !known {
		t.Fatal("c is a follow")
	}
	if n, follow, known := wt.Reach("x"); n != 5 || follow || !known {
		t.Fatalf("x: %d %v %v", n, follow, known)
	}
	if n, _, known := wt.Reach("stranger"); n != 0 || !known {
		t.Fatal("outside the second layer: 0 vouches")
	}
}

func TestWebShapeTellsAFollowsOnlyWebFromAWiderOne(t *testing.T) {
	wt := &SimpleInMemory{WotDepth: 2}
	if d, f, v := wt.WebShape(); d != 2 || f != 0 || v != 0 {
		t.Fatalf("unbuilt depth 2: got %d/%d/%d", d, f, v)
	}
	// Depth 2 as the build stores it: follows, no vouch layer.
	wt.layers.Store(&layers{follows: []string{"a", "b", "c"}})
	if d, f, v := wt.WebShape(); d != 2 || f != 3 || v != 0 {
		t.Fatalf("depth 2: got %d/%d/%d, want 2/3/0", d, f, v)
	}
	// Depth 3: follows and the vouched second layer.
	wt = &SimpleInMemory{WotDepth: 3}
	wt.layers.Store(&layers{follows: []string{"a", "b", "c"}, vouches: map[string]int{"x": 2, "y": 1}})
	if d, f, v := wt.WebShape(); d != 3 || f != 3 || v != 2 {
		t.Fatalf("depth 3: got %d/%d/%d, want 3/3/2", d, f, v)
	}
}
