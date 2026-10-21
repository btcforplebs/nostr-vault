package main

import (
	"context"
	"sync"
)

// appForeground is whether the host app is on screen. Work that only serves
// what the person is looking at (the Popular tally's engagement firehose)
// runs only while it is. It starts true: the Mac app and the standalone
// relay never report, so they keep running everything as before.
var appForeground = newForegroundGate(true)

type foregroundGate struct {
	mu      sync.Mutex
	on      bool
	changed chan struct{} // closed and replaced on every change
}

func newForegroundGate(on bool) *foregroundGate {
	return &foregroundGate{on: on, changed: make(chan struct{})}
}

// set records whether the app is on screen.
func (g *foregroundGate) set(on bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.on == on {
		return
	}
	g.on = on
	close(g.changed)
	g.changed = make(chan struct{})
}

func (g *foregroundGate) state() (bool, <-chan struct{}) {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.on, g.changed
}

func (g *foregroundGate) isOn() bool {
	on, _ := g.state()
	return on
}

// wait blocks until the app is on screen. False when ctx ends first.
func (g *foregroundGate) wait(ctx context.Context) bool {
	for {
		on, changed := g.state()
		if on {
			return true
		}
		select {
		case <-ctx.Done():
			return false
		case <-changed:
		}
	}
}

// context returns a child of ctx that is cancelled when the app leaves the
// screen. Call it while the app is on screen.
func (g *foregroundGate) context(ctx context.Context) (context.Context, context.CancelFunc) {
	child, cancel := context.WithCancel(ctx)
	go func() {
		for {
			on, changed := g.state()
			if !on {
				cancel()
				return
			}
			select {
			case <-child.Done():
				return
			case <-changed:
			}
		}
	}()
	return child, cancel
}
