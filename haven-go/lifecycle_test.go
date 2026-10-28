package main

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// TestLifecycleStress hammers startCycle/stopCycle from many goroutines.
// Each cycle spawns workers shaped like the real ones: one panics
// immediately, one blocks on ctx, one mutates shared state guarded the
// same way the dbs map is. Run with -race. Asserts: never two live
// cycles, stop-after-stop is a no-op, teardown always sees all workers
// drained, and no panic escapes to the test process.
func TestLifecycleStress(t *testing.T) {
	var lc lifecycleManager
	var liveCycles atomic.Int32
	var dbMu sync.Mutex
	dbOpen := false

	start := func() error {
		return lc.startCycle(func(c *relayCycle) error {
			dbMu.Lock()
			if dbOpen {
				dbMu.Unlock()
				return errors.New("db already open: overlapping cycles")
			}
			dbOpen = true
			dbMu.Unlock()

			if liveCycles.Add(1) > 1 {
				return errors.New("two live cycles")
			}

			c.spawn("panicker", func() { panic("deliberate test panic") })
			c.spawn("ctx-blocker", func() { <-c.ctx.Done() })
			c.spawn("db-writer", func() {
				for c.ctx.Err() == nil {
					dbMu.Lock()
					if !dbOpen {
						dbMu.Unlock()
						t.Error("worker observed closed DB while cycle live")
						return
					}
					dbMu.Unlock()
					time.Sleep(time.Microsecond)
				}
			})
			return nil
		})
	}

	stop := func() {
		lc.stopCycle(func(c *relayCycle) {
			if !c.waitBackground(2 * time.Second) {
				t.Error("workers did not drain within 2s")
			}
			liveCycles.Add(-1)
			dbMu.Lock()
			dbOpen = false
			dbMu.Unlock()
		})
	}

	var wg sync.WaitGroup
	for w := 0; w < 8; w++ {
		wg.Add(1)
		go func(seed int) {
			defer wg.Done()
			for i := 0; i < 25; i++ {
				if (seed+i)%2 == 0 {
					err := start()
					if err != nil && err != errAlreadyRunning {
						t.Errorf("startCycle: %v", err)
					}
				} else {
					stop()
				}
			}
		}(w)
	}
	wg.Wait()
	stop() // final cleanup; must be a no-op if already stopped

	if n := liveCycles.Load(); n != 0 {
		t.Fatalf("expected 0 live cycles at end, got %d", n)
	}
}

// TestLifecycleImportAbort verifies the two-phase stop: a long-running
// import holds the lifecycle mutex for its whole duration, and stopCycle's
// lock-free cancel phase must abort it rather than deadlocking.
func TestLifecycleImportAbort(t *testing.T) {
	var lc lifecycleManager

	importDone := make(chan struct{})
	importStarted := make(chan struct{})

	go func() {
		// Simulates runImportCycle: holds mu for the whole import.
		lc.mu.Lock()
		defer lc.mu.Unlock()
		ctx, cancel := context.WithCancel(context.Background())
		c := &relayCycle{ctx: ctx, cancel: cancel}
		lc.current.Store(c)
		defer func() {
			lc.current.Swap(nil)
			cancel()
			close(importDone)
		}()
		close(importStarted)
		select {
		case <-ctx.Done(): // aborted by stopCycle phase 1
		case <-time.After(10 * time.Second):
			t.Error("import was never cancelled")
		}
	}()

	<-importStarted
	stopReturned := make(chan struct{})
	go func() {
		lc.stopCycle(func(c *relayCycle) {
			t.Error("teardown must not run: import cleans up after itself")
		})
		close(stopReturned)
	}()

	select {
	case <-importDone:
	case <-time.After(5 * time.Second):
		t.Fatal("import did not abort within 5s")
	}
	select {
	case <-stopReturned:
	case <-time.After(5 * time.Second):
		t.Fatal("stopCycle did not return within 5s")
	}
}

// TestStartAfterStopSeesCleanState verifies sequential start→stop→start
// works and the second cycle is a distinct instance.
func TestStartAfterStopSeesCleanState(t *testing.T) {
	var lc lifecycleManager

	var first, second *relayCycle
	if err := lc.startCycle(func(c *relayCycle) error { first = c; return nil }); err != nil {
		t.Fatal(err)
	}
	if err := lc.startCycle(func(c *relayCycle) error { return nil }); err != errAlreadyRunning {
		t.Fatalf("expected errAlreadyRunning, got %v", err)
	}
	lc.stopCycle(func(c *relayCycle) {
		if c != first {
			t.Error("teardown received wrong cycle")
		}
	})
	if err := lc.startCycle(func(c *relayCycle) error { second = c; return nil }); err != nil {
		t.Fatal(err)
	}
	if first == second {
		t.Fatal("second cycle must be a fresh instance")
	}
	if first.ctx.Err() == nil {
		t.Fatal("first cycle's context must be cancelled after stop")
	}
	if second.ctx.Err() != nil {
		t.Fatal("second cycle's context must be live")
	}
	lc.stopCycle(func(c *relayCycle) {})
}

// TestStartWaitsForLastCycleToDrain: a stop that had to leave goroutines
// behind hands back a drained channel; until it closes, no new cycle may
// start beside them.
func TestStartWaitsForLastCycleToDrain(t *testing.T) {
	var lc lifecycleManager
	old := drainWait
	drainWait = 50 * time.Millisecond
	defer func() { drainWait = old }()

	if err := lc.startCycle(func(c *relayCycle) error { return nil }); err != nil {
		t.Fatal(err)
	}
	drained := make(chan struct{})
	lc.stopCycle(func(c *relayCycle) { lc.setDrained(drained) })

	setupRan := false
	if err := lc.startCycle(func(c *relayCycle) error { setupRan = true; return nil }); err != errStillDraining {
		t.Fatalf("start while draining = %v, want errStillDraining", err)
	}
	if setupRan {
		t.Fatal("setup ran while the last cycle was still draining")
	}
	close(drained)
	if err := lc.startCycle(func(c *relayCycle) error { return nil }); err != nil {
		t.Fatalf("start after drain = %v", err)
	}
	lc.stopCycle(func(c *relayCycle) {})
}
