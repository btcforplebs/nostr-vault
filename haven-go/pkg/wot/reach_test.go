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
