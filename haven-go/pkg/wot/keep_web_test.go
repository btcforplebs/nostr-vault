package wot

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// A rebuild that fetches nothing (offline, seed relays down, the relay
// stopping) must keep the saved web, not replace it with just the owner:
// the globe would empty and inbox/chat would turn strangers away.
func TestRebuildThatFetchesNothingKeepsTheWeb(t *testing.T) {
	cases := map[string]struct {
		relays    func(t *testing.T, owner, a testKey) []string
		cancelled bool
	}{
		"offline":  {relays: func(*testing.T, testKey, testKey) []string { return nil }},
		"stopping": {relays: func(t *testing.T, owner, a testKey) []string { return []string{seedRelay(t, owner.followList(t, a))} }, cancelled: true},
		// The owner's list arrives but none of the follows' lists do.
		"no follows' lists": {relays: func(t *testing.T, owner, a testKey) []string { return []string{seedRelay(t, owner.followList(t, a))} }},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			owner, a, b, c := newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t)
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			path := filepath.Join(t.TempDir(), "wot_cache.json")
			wt := NewSimpleInMemory(nostr.NewSimplePool(ctx), map[string]struct{}{owner.pk: {}},
				tc.relays(t, owner, a), 3, 1, 2, path, 60)
			wt.pubkeys.Store(&map[string]bool{owner.pk: true, a.pk: true, b.pk: true, c.pk: true})
			wt.SaveCache()
			before, _ := os.ReadFile(path)

			runCtx := ctx
			if tc.cancelled {
				c, stop := context.WithCancel(ctx)
				stop()
				runCtx = c
			}
			wt.Refresh(runCtx)

			if got := wt.Size(); got != 4 {
				t.Errorf("graph holds %d, want the 4 it had", got)
			}
			after, _ := os.ReadFile(path)
			if string(after) != string(before) {
				t.Error("the saved web was overwritten")
			}
			if p := CurrentProgress(); p.Phase != "stopped" {
				t.Errorf("progress phase %q, want stopped", p.Phase)
			}
		})
	}
}

// Following people who have no lists anywhere still grows the web, so that
// rebuild saves even though it fetched none of their lists.
func TestNewFollowsWithoutListsStillSave(t *testing.T) {
	owner, a, b := newTestKey(t), newTestKey(t), newTestKey(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	path := filepath.Join(t.TempDir(), "wot_cache.json")
	wt := NewSimpleInMemory(nostr.NewSimplePool(ctx), map[string]struct{}{owner.pk: {}},
		[]string{seedRelay(t, owner.followList(t, a, b))}, 3, 1, 2, path, 60)
	wt.pubkeys.Store(&map[string]bool{owner.pk: true, a.pk: true})

	wt.Refresh(ctx)

	if !wt.Has(ctx, b.pk) {
		t.Fatal("a new follow was not saved")
	}
	if p := CurrentProgress(); p.Phase != "saved" {
		t.Errorf("progress phase %q, want saved", p.Phase)
	}
}

// SaveCache replaces the file in one step and leaves no temp file behind.
func TestSaveCacheLeavesNoTempFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "wot_cache.json")
	wt := NewSimpleInMemory(nil, map[string]struct{}{"owner": {}}, nil, 3, 1, 1, path, 60)
	wt.pubkeys.Store(&map[string]bool{"owner": true})
	wt.SaveCache()
	if _, err := os.Stat(path + ".tmp"); !os.IsNotExist(err) {
		t.Fatalf("temp file left behind: %v", err)
	}
	if ok, _ := NewSimpleInMemory(nil, nil, nil, 3, 1, 1, path, 60).LoadFromCache(); !ok {
		t.Fatal("saved cache does not load")
	}
}
