package main

import (
	"context"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/fiatjaf/khatru"
	"github.com/nbd-wtf/go-nostr"
)

// fetchAnswered counts only relays that sent EOSE: an unreachable one ends
// the fetch the same way but does not count. Each event is handed over once.
func TestFetchAnsweredCountsEOSE(t *testing.T) {
	prevPool := pool
	t.Cleanup(func() { pool = prevPool })
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	pool = nostr.NewSimplePool(ctx)

	sk := nostr.GeneratePrivateKey()
	ev := nostr.Event{Kind: 1, CreatedAt: nostr.Now(), Content: "x"}
	ev.Sign(sk)
	newRelay := func() string {
		rl := khatru.NewRelay()
		rl.QueryEvents = append(rl.QueryEvents, func(_ context.Context, f nostr.Filter) (chan *nostr.Event, error) {
			ch := make(chan *nostr.Event, 1)
			ch <- &ev
			close(ch)
			return ch, nil
		})
		srv := httptest.NewServer(rl)
		t.Cleanup(srv.Close)
		return "ws" + strings.TrimPrefix(srv.URL, "http")
	}
	a, b := newRelay(), newRelay()
	dead := httptest.NewServer(khatru.NewRelay())
	deadURL := "ws" + strings.TrimPrefix(dead.URL, "http")
	dead.Close()

	got := 0
	n := fetchAnswered(ctx, []string{a, b, deadURL}, nostr.Filter{Kinds: []int{1}}, func(nostr.RelayEvent) { got++ })
	if n != 2 {
		t.Fatalf("answered = %d, want 2", n)
	}
	if got != 1 {
		t.Fatalf("events handed over = %d, want 1", got)
	}
	if n := fetchAnswered(ctx, []string{deadURL}, nostr.Filter{Kinds: []int{1}}, func(nostr.RelayEvent) {}); n != 0 {
		t.Fatalf("answered = %d with only a dead relay, want 0", n)
	}
}
