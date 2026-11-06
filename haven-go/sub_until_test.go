package main

import (
	"context"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// A subscription channel that never closes (a relay goroutine stuck dialling
// or on a frozen socket) must not keep the cycle's subscriber alive after a
// stop: the stop's 2 s wait sees every goroutine gone, the cycle drains, and
// the next start (Import notes) is not refused as still_draining.
func TestAStuckSubscriptionDoesNotHoldTheStop(t *testing.T) {
	var lc lifecycleManager
	stuck := make(chan nostr.RelayEvent) // never closed, never sent on
	got := 0
	if err := lc.startCycle(func(c *relayCycle) error {
		c.spawn("subscribeInboxAndChat", func() {
			for c.ctx.Err() == nil {
				eventsUntilDone(c.ctx, stuck, func(nostr.RelayEvent) { got++ })
			}
		})
		c.spawn("ingestPopularEngagement", func() {
			eventsUntilDone(c.ctx, stuck, func(nostr.RelayEvent) { got++ })
		})
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	drainedInTime := false
	lc.stopCycle(func(c *relayCycle) {
		drainedInTime = c.waitBackground(500 * time.Millisecond)
		if !drainedInTime {
			t.Errorf("still running after the stop: %v", c.stillRunning())
			lc.setDrained(make(chan struct{}))
			return
		}
		closed := make(chan struct{})
		close(closed)
		lc.setDrained(closed)
	})
	if lc.isDraining() {
		t.Fatal("the vault is still draining: an import would be refused")
	}
	if err := lc.startCycle(func(c *relayCycle) error { return nil }); err != nil {
		t.Fatalf("next start after the stop = %v, want it to run", err)
	}
	lc.stopCycle(func(c *relayCycle) {})
	if got != 0 {
		t.Fatalf("handled %d events from a channel that sent none", got)
	}
}

func TestEventsUntilDoneHandsOverEventsUntilTheChannelCloses(t *testing.T) {
	ch := make(chan nostr.RelayEvent, 2)
	ch <- nostr.RelayEvent{Event: &nostr.Event{ID: "a"}}
	ch <- nostr.RelayEvent{Event: &nostr.Event{ID: "b"}}
	close(ch)
	var ids []string
	eventsUntilDone(context.Background(), ch, func(ev nostr.RelayEvent) { ids = append(ids, ev.ID) })
	if len(ids) != 2 || ids[0] != "a" || ids[1] != "b" {
		t.Fatalf("got %v, want [a b]", ids)
	}
}
