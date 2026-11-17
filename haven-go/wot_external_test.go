package main

import (
	"context"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/fiatjaf/khatru"
	"github.com/nbd-wtf/go-nostr"
)

// citrineRelay is an outside relay (Citrine) holding events; it answers
// every REQ with the ones the filter matches.
func citrineRelay(t *testing.T, events ...*nostr.Event) string {
	t.Helper()
	rl := khatru.NewRelay()
	rl.QueryEvents = append(rl.QueryEvents, func(_ context.Context, f nostr.Filter) (chan *nostr.Event, error) {
		ch := make(chan *nostr.Event, len(events))
		for _, ev := range events {
			if f.Matches(ev) {
				ch <- ev
			}
		}
		close(ch)
		return ch, nil
	})
	srv := httptest.NewServer(rl)
	t.Cleanup(func() { srv.CloseClientConnections(); srv.Close() })
	return "ws" + strings.TrimPrefix(srv.URL, "http")
}

func signedFollowList(t *testing.T, sk string, at nostr.Timestamp, follows ...string) *nostr.Event {
	t.Helper()
	ev := &nostr.Event{Kind: nostr.KindFollowList, CreatedAt: at}
	for _, pk := range follows {
		ev.Tags = append(ev.Tags, nostr.Tag{"p", pk})
	}
	if err := ev.Sign(sk); err != nil {
		t.Fatal(err)
	}
	return ev
}

func newKey(t *testing.T) (sk, pk string) {
	t.Helper()
	sk = nostr.GeneratePrivateKey()
	pk, _ = nostr.GetPublicKey(sk)
	return sk, pk
}

// In Citrine mode the owner's follow list is on Citrine, not in our outbox
// database: the web is built from Citrine's newest list per owner, and no one
// else's.
func TestFollowListsFromOutsideRelayTakesTheOwnersNewest(t *testing.T) {
	skA, pkA := newKey(t)
	skB, pkB := newKey(t)
	skS, _ := newKey(t)
	_, friendOld := newKey(t)
	_, friendNew := newKey(t)
	_, friendB := newKey(t)
	note := &nostr.Event{Kind: 1, CreatedAt: 1_700_000_500, Content: "hi"}
	note.Sign(skA)
	url := citrineRelay(t,
		signedFollowList(t, skA, 1_700_000_000, friendOld),
		signedFollowList(t, skA, 1_700_000_100, friendNew),
		signedFollowList(t, skB, 1_700_000_050, friendB),
		signedFollowList(t, skS, 1_700_000_900, friendOld), // a stranger
		note,
	)
	ctx := context.Background()
	p := nostr.NewSimplePool(ctx)
	defer p.Close("test")

	lists := followListsFrom(ctx, p, url, []string{pkA, pkB})
	got := map[string]string{}
	for _, ev := range lists {
		got[ev.PubKey] = ev.Tags[0][1]
	}
	if len(lists) != 2 || got[pkA] != friendNew || got[pkB] != friendB {
		t.Fatalf("want A's newest list and B's, got %d lists %v", len(lists), got)
	}
}

func TestFollowListsFromOutsideRelayNeedsAnAddressAndOwners(t *testing.T) {
	ctx := context.Background()
	p := nostr.NewSimplePool(ctx)
	defer p.Close("test")
	if got := followListsFrom(ctx, p, "", []string{"x"}); got != nil {
		t.Fatalf("no address: want nil, got %v", got)
	}
	if got := followListsFrom(ctx, p, "ws://127.0.0.1:1", nil); got != nil {
		t.Fatalf("no owners: want nil, got %v", got)
	}
}
