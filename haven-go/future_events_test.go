package main

import (
	"context"
	"errors"
	"testing"

	"github.com/nbd-wtf/go-nostr"
)

func TestIsFutureEventAllowsTenMinutesOfSkew(t *testing.T) {
	now := nostr.Timestamp(1_800_000_000)
	for _, c := range []struct {
		at   nostr.Timestamp
		want bool
	}{
		{now - 86400*90, false}, // old notes are fine
		{now, false},
		{now + 600, false}, // a clock up to 10 minutes fast
		{now + 601, true},
		{now + 86400*365, true},
	} {
		if got := isFutureEvent(&nostr.Event{CreatedAt: c.at}, now); got != c.want {
			t.Errorf("at now%+d: got %v, want %v", c.at-now, got, c.want)
		}
	}
}

// Every write goes through the gate, so imports and backups can't store
// (and then broadcast) an event dated in the future either.
func TestGatedDBRefusesFutureEvents(t *testing.T) {
	g := newGatedDB(newFakeStore(0))
	defer g.Close()
	ctx := context.Background()
	future := &nostr.Event{CreatedAt: nostr.Now() + 86400}
	if err := g.SaveEvent(ctx, future); !errors.Is(err, errFutureEvent) {
		t.Fatalf("SaveEvent future: got %v, want errFutureEvent", err)
	}
	if err := g.ReplaceEvent(ctx, future); !errors.Is(err, errFutureEvent) {
		t.Fatalf("ReplaceEvent future: got %v, want errFutureEvent", err)
	}
	if err := g.SaveEvent(ctx, &nostr.Event{CreatedAt: nostr.Now()}); err != nil {
		t.Fatalf("SaveEvent now: %v", err)
	}
}
