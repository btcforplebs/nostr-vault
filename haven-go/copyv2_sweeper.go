//go:build !(js && wasm)

package main

import (
	"context"
	"time"

	"github.com/barrydeen/haven/pkg/runsafe"
)

// copySweepEvery: how often a running engine drops copies past copyKeepFor.
// Before this, sweep() ran only when another device started or read a copy,
// so a built media.zip (gigabytes) stayed on disk until that happened, often
// never (LogePhone 2026-11-26: 5.64 GB from a copy two days old).
const copySweepEvery = time.Hour

// sweepNow runs sweep under the lock.
func (s *copyServer) sweepNow() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sweep()
}

// startCopySweeper sweeps once at engine start (no copy from an earlier run
// can be read: its token lived in memory) and then every copySweepEvery
// until ctx ends.
func startCopySweeper(ctx context.Context) {
	copyV2.sweepNow()
	runsafe.Go("copy-sweep", func() {
		t := time.NewTicker(copySweepEvery)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				copyV2.sweepNow()
			}
		}
	})
}

// copyIDName: a copy's folder name, 32 lower-case hex characters.
func copyIDName(name string) bool {
	if len(name) != 32 {
		return false
	}
	for _, c := range name {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}
