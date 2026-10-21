package wot

import (
	"context"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// The app's button, the daily timer and the boot check can ask at once; only
// one rebuild may run, and the progress has to say when it's done.
func TestRefreshNowRunsOnceAndReportsSaved(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	wt := NewSimpleInMemory(nostr.NewSimplePool(ctx), map[string]struct{}{"owner": {}},
		nil, 2, 1, 1, filepath.Join(t.TempDir(), "wot_cache.json"), 60)

	if !claimRefresh() {
		t.Fatal("nothing running yet, claim refused")
	}
	if !CurrentProgress().Running || CurrentProgress().Phase != "follows" {
		t.Fatalf("claimed rebuild not reported as running: %+v", CurrentProgress())
	}
	var spawned int
	if !RefreshNow(ctx, wt, func(string, func()) { spawned++ }) || spawned != 0 {
		t.Fatalf("a rebuild already running must count as started and not spawn another (spawned %d)", spawned)
	}
	wt.Refresh(ctx) // the timer, while one runs: skipped
	if !CurrentProgress().Running {
		t.Fatal("a skipped Refresh released the running rebuild's claim")
	}
	releaseRefresh("saved", 1)

	var wg sync.WaitGroup
	if !RefreshNow(ctx, wt, func(_ string, fn func()) { wg.Add(1); go func() { defer wg.Done(); fn() }() }) {
		t.Fatal("RefreshNow refused an idle depth-2 model")
	}
	wg.Wait()
	p := CurrentProgress()
	if p.Running || p.Phase != "saved" || p.Size != 1 || p.FinishedAt == 0 {
		t.Fatalf("finished rebuild reported as %+v", p)
	}
	if RefreshNow(ctx, NewSimpleInMemory(nil, nil, nil, 0, 1, 1, "", 60), func(string, func()) {}) {
		t.Error("depth 0 has no graph to rebuild")
	}
}
