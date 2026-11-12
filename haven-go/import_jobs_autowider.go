package main

import (
	"context"
	"log"
)

// autoStartWider: once setup has ended (done or partial), the wider web
// (follows of follows) starts by itself if it has never run, so Underrated,
// Popular, Global and Discover fill without the user finding the button
// (Logen, 2026-11-12). Called by the runner after setup's result is saved and
// before setup's done channel closes, so a wait() for setup returns while the
// wider build runs on in the background. A user who already ran or cancelled
// it keeps their choice.
func (r *jobRunner) autoStartWider(ctx context.Context, start func() int) {
	if ctx.Err() != nil {
		return
	}
	jobsMu.Lock()
	f := loadJobsFile()
	jobsMu.Unlock()
	setup, wider := f.job(jobSetup), f.job(jobWiderNetwork)
	if setup == nil || (setup.Status != jobDone && setup.Status != jobPartial) {
		return
	}
	if wider != nil && wider.Status != jobNever {
		return
	}
	if rc := start(); rc != runStarted {
		log.Printf("wider network did not start after setup: %d", rc)
		return
	}
	log.Printf("🌐 setup finished: building the wider web in the background")
}
