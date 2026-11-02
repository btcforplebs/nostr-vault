package nostr

import (
	"context"
	"fmt"
	"testing"
	"time"
)

// drained waits for subMany's events channel to close, or fails after d.
func drained(t *testing.T, events chan RelayEvent, d time.Duration) {
	t.Helper()
	timeout := time.After(d)
	for {
		select {
		case _, more := <-events:
			if !more {
				return
			}
		case <-timeout:
			t.Fatal("events was never closed")
		}
	}
}

// Every relay goroutine ends at once when the context is already cancelled.
// Before the fix two of them could both see the count at 0 and both close
// events, a "close of closed channel" panic that killed the app on relay
// shutdown (pool.go:493, 3.1.0 build 52).
func TestSubManyClosesEventsOnceWhenAllRelaysEndTogether(t *testing.T) {
	pool := NewSimplePool(context.Background())
	urls := make([]string, 64)
	for i := range urls {
		urls[i] = fmt.Sprintf("wss://relay%d.invalid", i)
	}
	for round := 0; round < 200; round++ {
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		events := pool.subMany(ctx, append([]string(nil), urls...), Filters{{Kinds: []int{1}}}, nil)
		drained(t, events, 5*time.Second)
	}
}

// A relay listed twice runs once. Before the fix it was counted twice, so
// events never closed and a caller ranging over it hung.
func TestSubManyClosesEventsWithDuplicateRelays(t *testing.T) {
	pool := NewSimplePool(context.Background())
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	urls := []string{"wss://relay.invalid", "wss://relay.invalid/", "wss://other.invalid", "wss://relay.invalid"}
	eose := make(chan struct{})
	events := pool.subMany(ctx, urls, Filters{{Kinds: []int{1}}}, eose)
	drained(t, events, 5*time.Second)
	select {
	case <-eose:
	case <-time.After(5 * time.Second):
		t.Fatal("eose never closed")
	}
}
