package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/fasthttp/websocket"
	"github.com/fiatjaf/eventstore"
	"github.com/nbd-wtf/go-nostr"
)

// flappingRelay answers every REQ with one event and then CLOSED: the relay
// that replays the window and drops the subscription. It counts REQs.
func flappingRelay(t *testing.T, ev nostr.Event) (string, *atomic.Int32) {
	var reqs atomic.Int32
	up := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := up.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer c.Close()
		for {
			_, msg, err := c.ReadMessage()
			if err != nil {
				return
			}
			var frame []json.RawMessage
			if json.Unmarshal(msg, &frame) != nil || len(frame) < 2 {
				continue
			}
			var typ, id string
			json.Unmarshal(frame[0], &typ)
			json.Unmarshal(frame[1], &id)
			if typ != "REQ" {
				continue
			}
			reqs.Add(1)
			evb, _ := json.Marshal(ev)
			c.WriteMessage(websocket.TextMessage, []byte(`["EVENT","`+id+`",`+string(evb)+`]`))
			c.WriteMessage(websocket.TextMessage, []byte(`["EOSE","`+id+`"]`))
			// Let the event reach the subscriber before the close cancels it.
			time.Sleep(200 * time.Millisecond)
			c.WriteMessage(websocket.TextMessage, []byte(`["CLOSED","`+id+`","error: going away"]`))
		}
	}))
	t.Cleanup(srv.Close)
	return "ws" + strings.TrimPrefix(srv.URL, "http"), &reqs
}

// A relay that sends a wrap and closes the subscription each time must be
// reopened on a growing backoff. Resetting on "an event arrived" reopened it
// every second, re-sending the two-day window each time.
func TestFlappingGiftWrapSubscriptionBacksOff(t *testing.T) {
	prevConfig, prevPool := config, pool
	t.Cleanup(func() { config, pool = prevConfig, prevPool })
	ctx, cancel := context.WithTimeout(context.Background(), 6500*time.Millisecond)
	defer cancel()
	pool = nostr.NewSimplePool(ctx)

	owner := nostr.GeneratePrivateKey()
	ownerPK, _ := nostr.GetPublicKey(owner)
	sender := nostr.GeneratePrivateKey()
	senderPK, _ := nostr.GetPublicKey(sender)
	// The sender is blacklisted so the wrap is dropped before any store.
	config.WhitelistedPubKeys = map[string]struct{}{ownerPK: {}}
	config.BlacklistedPubKeys = map[string]struct{}{senderPK: {}}
	wrap := nostr.Event{Kind: nostr.KindGiftWrap, CreatedAt: nostr.Now(), Tags: nostr.Tags{{"p", ownerPK}}}
	wrap.Sign(sender)

	url, reqs := flappingRelay(t, wrap)
	subscribeLiveGiftWraps(ctx, []string{url}, []string{ownerPK}, eventstore.RelayWrapper{}, eventstore.RelayWrapper{}, &tempRejects{})

	// 1 s, 2 s, 4 s waits: opens at about 0, 1 and 3 s in a 6.5 s window.
	// A one-second reset opens it about 7 times.
	if n := reqs.Load(); n < 2 || n > 4 {
		t.Fatalf("subscription opened %d times in 6.5 s, want 2-4", n)
	}
}
