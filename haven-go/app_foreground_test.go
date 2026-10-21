package main

import (
	"context"
	"testing"
	"time"
)

func TestForegroundContextEndsWhenAppBackgrounds(t *testing.T) {
	g := newForegroundGate(true)
	ctx, cancel := g.context(context.Background())
	defer cancel()
	g.set(false)
	select {
	case <-ctx.Done():
	case <-time.After(time.Second):
		t.Fatal("subscription context still open after the app backgrounded")
	}
}

func TestWaitBlocksUntilForeground(t *testing.T) {
	g := newForegroundGate(false)
	got := make(chan bool, 1)
	go func() { got <- g.wait(context.Background()) }()
	select {
	case <-got:
		t.Fatal("wait returned while the app was in the background")
	case <-time.After(50 * time.Millisecond):
	}
	g.set(true)
	select {
	case ok := <-got:
		if !ok {
			t.Fatal("wait reported false after foreground")
		}
	case <-time.After(time.Second):
		t.Fatal("wait did not return after the app came to the foreground")
	}
}

func TestWaitEndsWithContext(t *testing.T) {
	g := newForegroundGate(false)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if g.wait(ctx) {
		t.Fatal("wait reported foreground on a cancelled context")
	}
}
