package wot

import (
	"context"
	"sync"
	"sync/atomic"
	"time"
)

// Progress is how far a graph rebuild has got, for the apps' "update your
// web" bar. Phases run "follows" (the owner's own follow lists), "lists"
// (their follows' lists, in batches), "counting", then "saved". A rebuild
// cut short by the relay stopping ends at "stopped".
type Progress struct {
	Running     bool   `json:"running"`
	Phase       string `json:"phase"`
	Batches     int    `json:"batches"`
	BatchesDone int    `json:"batchesDone"`
	// Follow lists read so far, across every phase.
	Lists int64 `json:"lists"`
	// People in the graph once saved.
	Size       int   `json:"size"`
	FinishedAt int64 `json:"finishedAt"`
}

var (
	refreshing    atomic.Bool
	progressMu    sync.Mutex
	progressState Progress
)

// CurrentProgress is a copy of the latest rebuild's progress.
func CurrentProgress() Progress {
	progressMu.Lock()
	defer progressMu.Unlock()
	return progressState
}

func updateProgress(change func(*Progress)) {
	progressMu.Lock()
	change(&progressState)
	progressMu.Unlock()
}

// claimRefresh lets one rebuild run at a time: the daily timer, the boot-time
// stale check and the app's button can all ask at once.
func claimRefresh() bool {
	if !refreshing.CompareAndSwap(false, true) {
		return false
	}
	updateProgress(func(p *Progress) {
		*p = Progress{Running: true, Phase: "follows", Size: p.Size, FinishedAt: p.FinishedAt}
	})
	return true
}

func releaseRefresh(phase string, size int) {
	updateProgress(func(p *Progress) {
		p.Running = false
		p.Phase = phase
		if phase == "saved" {
			p.Size = size
			p.FinishedAt = time.Now().Unix()
		}
	})
	refreshing.Store(false)
}

// RefreshNow starts a rebuild in the background through spawn (the relay
// cycle's, so stopping the relay waits for it). False when the model can't
// rebuild; true when one started or was already running.
func RefreshNow(ctx context.Context, model Model, spawn func(name string, fn func())) bool {
	wt, ok := model.(*SimpleInMemory)
	if !ok || wt.WotDepth == 0 {
		return false
	}
	if !claimRefresh() {
		return true
	}
	spawn("wot.Refresh.manual", func() { wt.build(ctx) })
	return true
}
