package wot

import (
	"context"
	"fmt"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"
)

type Model interface {
	Has(ctx context.Context, pubkey string) bool
}

type Refresher interface {
	Refresh(ctx context.Context)
}

type Initializer interface {
	Init(ctx context.Context)
}

var wotInstance atomic.Value

// ReadyGate signals completion of one WoT build cycle. Each relay
// start/stop cycle gets its own gate via NewCycle(); sync.Once makes
// marking ready idempotent, so a stale Initialize goroutine left over
// from a cancelled cycle can never double-close the channel (which
// previously panicked and took the whole host app down).
type ReadyGate struct {
	ch   chan struct{}
	once sync.Once
}

func newReadyGate() *ReadyGate { return &ReadyGate{ch: make(chan struct{})} }

func (g *ReadyGate) markReady() { g.once.Do(func() { close(g.ch) }) }

// Done returns a channel that closes when this cycle's WoT is ready.
func (g *ReadyGate) Done() <-chan struct{} { return g.ch }

// currentGate is the gate WaitReady() observes. Stale cycles keep their
// own gate reference, so marking a superseded gate ready is harmless.
var currentGate atomic.Pointer[ReadyGate]

func init() {
	currentGate.Store(newReadyGate())
}

func GetInstance() Model {
	val := wotInstance.Load()
	if val == nil {
		return nil
	}
	return val.(Model)
}

// NewCycle installs and returns a fresh ready gate. Call once per relay
// start cycle, before MarkReady or Initialize.
func NewCycle() *ReadyGate {
	g := newReadyGate()
	currentGate.Store(g)
	return g
}

// MarkReady signals the given cycle's WoT is ready without running
// Initialize(). Used when a valid cache was loaded and a rebuild is
// unnecessary.
func MarkReady(g *ReadyGate, model Model) {
	wotInstance.Store(model)
	g.markReady()
}

// WaitReady blocks until the current cycle's WoT is ready or ctx is done.
func WaitReady(ctx context.Context) {
	g := currentGate.Load()
	select {
	case <-g.Done():
	case <-ctx.Done():
	}
}

// Initialize builds the WoT and marks the given cycle's gate ready.
// A cancelled cycle returns without signalling readiness — a half-built
// graph must not unblock waiters, and the next cycle has its own gate.
func Initialize(ctx context.Context, model Model, g *ReadyGate) {
	wotInstance.Store(model)
	if initializer, ok := model.(Initializer); ok {
		slog.Info("🌐 Initializing WoT", "model", fmt.Sprintf("%T", model))
		initializer.Init(ctx)
		slog.Info("✅ WoT initialized")
	}
	if ctx.Err() != nil {
		return
	}
	g.markReady()
}

// EmptyGraphRefreshInterval is how often a graph that names nobody but the
// owner is rebuilt. A new account's first follows should reach its web of
// trust in minutes, not at the next daily refresh.
const EmptyGraphRefreshInterval = 2 * time.Minute

// RefreshWhileEmpty rebuilds the graph every interval while it names only the
// owners, so following people fills it soon after. Once it names anyone else
// this costs nothing; PeriodicRefresh takes over.
func RefreshWhileEmpty(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			refreshIfOnlyOwners(ctx, GetInstance())
		}
	}
}

type ownersOnly interface {
	NamesOnlyOwners() bool
}

func refreshIfOnlyOwners(ctx context.Context, instance any) bool {
	empty, ok := instance.(ownersOnly)
	if !ok || !empty.NamesOnlyOwners() {
		return false
	}
	refresher, ok := instance.(Refresher)
	if !ok {
		return false
	}
	slog.Info("🌱 Web of Trust names only the owner, checking for new follows")
	refresher.Refresh(ctx)
	return true
}

// PeriodicRefresh re-computes the WoT every interval for as long as the process
// stays alive. The ticker starts from zero on every call, so on a process that
// restarts often (a mobile app backgrounded/relaunched constantly, unlike a
// long-running Mac/server instance) it may go a very long time without ever
// firing — the boot-time age check in main.go/cshared.go (comparing the loaded
// cache's age against this same interval) is what actually keeps those
// installs from getting stuck on a stale cache indefinitely.
func PeriodicRefresh(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			instance := GetInstance()
			if refresher, ok := instance.(Refresher); ok {
				slog.Info("🌐 Refreshing WoT")
				refresher.Refresh(ctx)
				slog.Info("✅ WoT refreshed")
			}
		}
	}
}
