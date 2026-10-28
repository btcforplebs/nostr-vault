package main

import (
	"context"
	"errors"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// errDBClosing is what a call into a database gets once its relay cycle has
// begun closing it.
var errDBClosing = errors.New("database is closing")

// gatedDB guards one open database across relay cycles. Callers that are
// not owned by the cycle (khatru's per-message goroutines, request
// handlers, library forwarders) can still be inside the store when the
// relay stops. Closing Badger under them, or reopening the same path for
// the next cycle while they run, is use-after-close in Badger's manually
// managed memory: the Go GC then finds pointers to freed objects and
// aborts the whole app. The gate makes close wait for every call in
// flight, refuses new ones, and closes the store only when the last one
// leaves.
type gatedDB struct {
	inner DBBackend

	mu      sync.Mutex
	active  int           // calls in flight, including open query channels
	closing bool          // no new calls; inner closes when active reaches 0
	stop    chan struct{} // closed with closing: open queries stop forwarding
	closed  chan struct{}
}

func newGatedDB(inner DBBackend) *gatedDB {
	return &gatedDB{inner: inner, stop: make(chan struct{}), closed: make(chan struct{})}
}

func (g *gatedDB) enter() bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.closing {
		return false
	}
	g.active++
	return true
}

func (g *gatedDB) leave() {
	g.mu.Lock()
	g.active--
	last := g.closing && g.active == 0
	g.mu.Unlock()
	if last {
		g.closeInner()
	}
}

func (g *gatedDB) closeInner() {
	g.inner.Close()
	close(g.closed)
}

// beginClose refuses new calls and closes the store now if nothing is in
// flight, or else when the last call leaves. Done() reports the real close.
func (g *gatedDB) beginClose() {
	g.mu.Lock()
	if g.closing {
		g.mu.Unlock()
		return
	}
	g.closing = true
	close(g.stop)
	idle := g.active == 0
	g.mu.Unlock()
	if idle {
		g.closeInner()
	}
}

// Done is closed once the underlying store has been closed.
func (g *gatedDB) Done() <-chan struct{} { return g.closed }

func (g *gatedDB) Init() error { return nil } // the inner store is opened before gating

// Close closes the store, waiting for calls in flight to finish first.
func (g *gatedDB) Close() {
	g.beginClose()
	<-g.closed
}

func (g *gatedDB) Serial() []byte { return g.inner.Serial() }

func (g *gatedDB) CountEvents(ctx context.Context, f nostr.Filter) (int64, error) {
	if !g.enter() {
		return 0, errDBClosing
	}
	defer g.leave()
	return g.inner.CountEvents(ctx, f)
}

func (g *gatedDB) DeleteEvent(ctx context.Context, evt *nostr.Event) error {
	if !g.enter() {
		return errDBClosing
	}
	defer g.leave()
	return g.inner.DeleteEvent(ctx, evt)
}

func (g *gatedDB) SaveEvent(ctx context.Context, evt *nostr.Event) error {
	if !g.enter() {
		return errDBClosing
	}
	defer g.leave()
	return g.inner.SaveEvent(ctx, evt)
}

func (g *gatedDB) ReplaceEvent(ctx context.Context, evt *nostr.Event) error {
	if !g.enter() {
		return errDBClosing
	}
	defer g.leave()
	return g.inner.ReplaceEvent(ctx, evt)
}

// QueryEvents holds the gate until the store has finished its query and
// closed its channel. The store's goroutine keeps a read transaction open
// while it sends, so the forwarder always drains it to the end — even when
// ctx is cancelled and nobody reads out any more — instead of leaving it
// blocked inside the transaction. Once close begins it stops forwarding
// too: a reader that walked away without cancelling ctx (a backup that
// hit a write error, say) must not hold the store open forever.
func (g *gatedDB) QueryEvents(ctx context.Context, f nostr.Filter) (chan *nostr.Event, error) {
	if !g.enter() {
		return nil, errDBClosing
	}
	ch, err := g.inner.QueryEvents(ctx, f)
	if err != nil || ch == nil {
		g.leave()
		return ch, err
	}
	out := make(chan *nostr.Event)
	go func() {
		defer g.leave()
		defer close(out)
		for ev := range ch {
			select {
			case out <- ev:
			case <-ctx.Done():
				for range ch {
				}
				return
			case <-g.stop:
				for range ch {
				}
				return
			}
		}
	}()
	return out, nil
}

// closeGatedDBs starts closing every gate and waits up to d for the stores
// to actually close. It returns a channel that is closed once all of them
// have, so a store held by a straggler closes as soon as it is released.
func closeGatedDBs(gates []*gatedDB, d time.Duration) (allClosed <-chan struct{}, inTime bool) {
	for _, g := range gates {
		g.beginClose()
	}
	done := make(chan struct{})
	go func() {
		for _, g := range gates {
			<-g.Done()
		}
		close(done)
	}()
	select {
	case <-done:
		return done, true
	case <-time.After(d):
		return done, false
	}
}
