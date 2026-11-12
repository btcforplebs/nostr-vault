package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	"github.com/fiatjaf/khatru"
	"github.com/nbd-wtf/go-nostr"
)

// A connection as the apps open it to write what they pulled from relays
// (?pulled=1: FeedService and NetworkSyncService), or as a client posts.
func connCtx(target string) context.Context {
	return context.WithValue(context.Background(), 0, &khatru.WebSocket{Request: httptest.NewRequest(http.MethodGet, target, nil)})
}

// Logen's pick (2026-11-12): what the vault pulled from relays is stored and
// never blasted back to them; what is written locally (the apps posting,
// his own devices, clients) still is. The pulled re-blast was the source of
// the .99 storm (RESEARCH/NV_MAC_RELAY_PROFILE_2026_11_12.md).
func TestPulledEventsAreStoredNotBlasted(t *testing.T) {
	sk, pk := withOwner(t)
	db := withOutbox(t)
	relay := khatru.NewRelay()
	var mu sync.Mutex
	blasted := map[string]bool{}
	wireOutboxWrites(relay, db, func(ev *nostr.Event) {
		mu.Lock()
		blasted[ev.ID] = true
		mu.Unlock()
	})

	sign := func(kind int, content string, tags nostr.Tags) *nostr.Event {
		ev := &nostr.Event{PubKey: pk, Kind: kind, CreatedAt: nostr.Now(), Content: content, Tags: tags}
		ev.Sign(sk)
		return ev
	}
	pulledNote := sign(1, "pulled from a relay", nil)
	pulledProfile := sign(0, `{"name":"pulled"}`, nil)
	postedNote := sign(1, "posted from the app", nil)
	postedList := sign(30023, "posted article", nostr.Tags{{"d", "a"}})

	for _, c := range []struct {
		ctx context.Context
		ev  *nostr.Event
	}{
		{connCtx("/?pulled=1"), pulledNote},
		{connCtx("/?pulled=1"), pulledProfile},
		{connCtx("/"), postedNote},
		{connCtx("/?other=1"), postedList},
	} {
		if _, err := relay.AddEvent(c.ctx, c.ev); err != nil {
			t.Fatalf("kind %d: %v", c.ev.Kind, err)
		}
	}

	for _, ev := range []*nostr.Event{pulledNote, pulledProfile, postedNote, postedList} {
		if !outboxHolds(context.Background(), ev.ID) {
			t.Errorf("kind %d %q not stored", ev.Kind, ev.Content)
		}
	}
	if blasted[pulledNote.ID] || blasted[pulledProfile.ID] {
		t.Errorf("a pulled event was queued for blast")
	}
	if !blasted[postedNote.ID] || !blasted[postedList.ID] {
		t.Errorf("a locally posted event was not queued for blast")
	}
}
