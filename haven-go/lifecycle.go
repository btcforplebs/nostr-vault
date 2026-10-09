package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/pkg/runsafe"
)

// This file serializes the embedded relay's lifecycle for C-shared hosts
// (macOS/iOS Swift, Android JNI). Hosts historically could overlap
// StartRelayC with a still-running StopRelayC (e.g. a host-side stop
// timeout firing early), which raced the package globals: the in-flight
// stop cancelled the NEW cycle's context and closed the NEWLY opened
// databases, producing writes-to-closed-BadgerDB panics and concurrent
// map faults that killed the host app. All transitions now hold a single
// mutex, and every background goroutine registers with the cycle's
// WaitGroup so teardown can wait for them before closing databases.
//
// The standalone CLI (main.go) keeps its process-lifetime model and does
// not use this.

// relayCycle holds all per-start state. A new instance is created on
// every start and torn down exactly once by stop. Exported funcs snapshot
// it via relayLC.current so they never observe half-initialized state.
type relayCycle struct {
	ctx    context.Context
	cancel context.CancelFunc
	server *http.Server // nil in import mode
	// meshServer is the loopback port the FIPS mesh tunnel forwards to:
	// plain HTTP, blob GET/HEAD only (meshBlobHandler).
	meshServer *http.Server
	pool       *nostr.SimplePool
	wg         sync.WaitGroup
}

// spawn runs fn on a goroutine registered with the cycle's WaitGroup and
// panic-isolated via runsafe. Nested spawn calls are safe as long as the
// spawning goroutine itself was spawned (the counter is then ≥ 1).
func (c *relayCycle) spawn(name string, fn func()) {
	c.wg.Add(1)
	go func() {
		defer c.wg.Done()
		runsafe.Run(name, fn)
	}()
}

// waitBackground waits for all spawned goroutines, bounded by d.
// Returns false on timeout.
func (c *relayCycle) waitBackground(d time.Duration) bool {
	done := make(chan struct{})
	go func() { c.wg.Wait(); close(done) }()
	select {
	case <-done:
		return true
	case <-time.After(d):
		return false
	}
}

// lifecycleManager serializes start/stop/backup/restore transitions.
// current is an atomic pointer so read-only exported funcs (e.g.
// ComputePopularNotesC) can snapshot the live cycle without taking the
// mutex.
type lifecycleManager struct {
	mu      sync.Mutex
	current atomic.Pointer[relayCycle]
}

var relayLC lifecycleManager

var errAlreadyRunning = errors.New("relay already running")

// startCycle runs setup under the lifecycle mutex and installs the cycle
// on success. setup receives the fresh cycle (ctx/cancel populated) and
// must place server/pool on it and spawn goroutines via cycle.spawn.
func (l *lifecycleManager) startCycle(setup func(c *relayCycle) error) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.current.Load() != nil {
		return errAlreadyRunning
	}
	ctx, cancel := context.WithCancel(context.Background())
	c := &relayCycle{ctx: ctx, cancel: cancel}
	if err := setup(c); err != nil {
		cancel()
		c.waitBackground(5 * time.Second) // drain anything setup spawned
		return err
	}
	l.current.Store(c)
	return nil
}

// stopCycle tears down the live cycle, if any. Phase 1 cancels WITHOUT
// the lock so an in-flight import (which holds the lock for its whole
// duration) unblocks; phase 2 acquires the lock and performs the full
// teardown exactly once. Stopping an already-stopped relay is a no-op.
func (l *lifecycleManager) stopCycle(teardown func(c *relayCycle)) {
	if c := l.current.Load(); c != nil {
		c.cancel()
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	c := l.current.Swap(nil)
	if c == nil {
		return
	}
	c.cancel() // idempotent; covers a cycle installed between the phases
	teardown(c)
}

// withExclusiveDBs serializes operations that re-initialize and close the
// databases themselves (backup/restore). Hosts are expected to stop the
// relay first; this enforces it — an operation queued behind an in-flight
// stop waits for it, and one issued against a running relay is refused
// instead of racing the live cycle's databases and config.
func withExclusiveDBs(name string, fn func() int) int {
	relayLC.mu.Lock()
	defer relayLC.mu.Unlock()
	if relayLC.current.Load() != nil {
		log.Printf("🚫 %s refused: relay is running — stop it first", name)
		return 1
	}
	return fn()
}
