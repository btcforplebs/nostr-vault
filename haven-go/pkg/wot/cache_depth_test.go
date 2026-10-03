package wot

import (
	"context"
	"os"
	"path/filepath"
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
			nil, // no seed relays: depth 2 fetches nothing and falls back to the seeds
			depth, 1, 1, path, 60).WithFallbackSeeds([]string{"seed"})
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
