package wot

import (
	"context"
	"fmt"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// A new account following one person, with the apps' bar of 3: nobody can be
// vouched for by 3 follows, so the web used to stop at that one follow. It
// must take in who that follow follows.
func TestNewAccountWebTakesFollowsOfFollows(t *testing.T) {
	owner, a, x, y := newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t)
	relay := seedRelay(t,
		owner.followList(t, a),
		a.followList(t, x, y, owner),
	)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	wt := NewSimpleInMemory(nostr.NewSimplePool(ctx), map[string]struct{}{owner.pk: {}},
		[]string{relay}, 3, 3, 5, filepath.Join(t.TempDir(), "wot_cache.json"), 60)
	wt.Refresh(ctx)

	for name, k := range map[string]testKey{"owner": owner, "a": a, "x": x, "y": y} {
		if !wt.Has(ctx, k.pk) {
			t.Errorf("%s missing from a one-follow web", name)
		}
	}
	if wt.Size() != 4 {
		t.Errorf("web size %d, want 4 (owner, a, x, y)", wt.Size())
	}
	l := wt.layers.Load()
	if l == nil || l.vouches[x.pk] != 1 || l.vouches[y.pk] != 1 || len(l.vouches) != 2 {
		t.Errorf("vouches %v, want x:1 y:1", l)
	}
	if p := CurrentProgress(); p.Found != 3 {
		t.Errorf("progress found %d, want 3 (a, x, y)", p.Found)
	}
}

func TestNewAccountWebRanksAndCaps(t *testing.T) {
	counts := map[string]int{"owner": 1, "a": 1, "b": 1, "both": 2}
	for i := range newAccountWebCap + 50 {
		counts[fmt.Sprintf("p%05d", i)] = 1
	}
	web := map[string]bool{"owner": true, "a": true, "b": true}

	people := newAccountWeb(counts, web, 2, 3)
	if len(people) != newAccountWebCap {
		t.Fatalf("took %d people, want the cap of %d", len(people), newAccountWebCap)
	}
	if people[0] != "both" || slices.Contains(people, "a") || slices.Contains(people, "owner") {
		t.Errorf("want the most vouched first and nobody already in the web, got %v", people[:3])
	}
	if people[1] != "p00000" || people[len(people)-1] != fmt.Sprintf("p%05d", newAccountWebCap-2) {
		t.Errorf("ties must break by key so rebuilds agree, got %s .. %s", people[1], people[len(people)-1])
	}

	if got := newAccountWeb(counts, web, 3, 3); got != nil {
		t.Errorf("an owner with as many follows as the bar keeps the bar, got %d people", len(got))
	}
	if got := newAccountWeb(counts, web, 1, 0); got != nil {
		t.Error("no bar means the normal web already has everyone")
	}
}
