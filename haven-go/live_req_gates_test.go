package main

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/fasthttp/websocket"
	"github.com/nbd-wtf/go-nostr"
)

// A live-only REQ ("limit":0) returned in khatru before every read gate, so
// with no AUTH it was sent the owner's new /private and /chat events over
// plain https (Tron, #1966). Now the read gates run first. /inbox reads stay
// open by design.

type liveWS struct {
	t         *testing.T
	c         *websocket.Conn
	challenge string
}

func dialLive(t *testing.T, url string) *liveWS {
	t.Helper()
	c, _, err := websocket.DefaultDialer.Dial(url, nil)
	if err != nil {
		t.Fatalf("websocket %s: %v", url, err)
	}
	t.Cleanup(func() { c.Close() })
	return &liveWS{t: t, c: c}
}

func (w *liveWS) send(v any) {
	w.t.Helper()
	b, _ := json.Marshal(v)
	if err := w.c.WriteMessage(websocket.TextMessage, b); err != nil {
		w.t.Fatal(err)
	}
}

// read returns the next frame's label and fields, or "" at the deadline.
func (w *liveWS) read(deadline time.Time) (string, []json.RawMessage) {
	_ = w.c.SetReadDeadline(deadline)
	_, msg, err := w.c.ReadMessage()
	if err != nil {
		return "", nil
	}
	var arr []json.RawMessage
	if json.Unmarshal(msg, &arr) != nil || len(arr) == 0 {
		return "?", nil
	}
	var label string
	_ = json.Unmarshal(arr[0], &label)
	if label == "AUTH" && len(arr) > 1 {
		_ = json.Unmarshal(arr[1], &w.challenge)
	}
	return label, arr
}

func (w *liveWS) waitFor(label string) []json.RawMessage {
	w.t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		l, arr := w.read(deadline)
		if l == "" {
			w.t.Fatalf("no %s", label)
		}
		if l == label {
			return arr
		}
	}
}

func (w *liveWS) publish(ev nostr.Event) (bool, string) {
	w.t.Helper()
	w.send([]any{"EVENT", ev})
	ok := w.waitFor("OK")
	var accepted bool
	var msg string
	_ = json.Unmarshal(ok[2], &accepted)
	_ = json.Unmarshal(ok[3], &msg)
	return accepted, msg
}

func (w *liveWS) auth(sk, relay string) bool {
	w.t.Helper()
	if w.challenge == "" {
		w.waitFor("AUTH")
	}
	ev := nostr.Event{Kind: nostr.KindClientAuthentication, CreatedAt: nostr.Now(),
		Tags: nostr.Tags{{"relay", relay}, {"challenge", w.challenge}}}
	ev.Sign(sk)
	w.send([]any{"AUTH", ev})
	ok := w.waitFor("OK")
	var accepted bool
	_ = json.Unmarshal(ok[2], &accepted)
	return accepted
}

func (w *liveWS) gotEvent(wait time.Duration) bool {
	deadline := time.Now().Add(wait)
	for time.Now().Before(deadline) {
		if l, _ := w.read(deadline); l == "EVENT" {
			return true
		} else if l == "" {
			return false
		}
	}
	return false
}

func TestLiveOnlyREQFacesTheReadGatesDirect(t *testing.T) {
	h := startHaven(t)
	for i, c := range []struct {
		path      string
		kind      int
		wantEvent bool
	}{
		{"/private", 1, false},
		{"/chat", nostr.KindGiftWrap, false},
		{"/inbox", nostr.KindGiftWrap, true}, // /inbox reads are open over https
	} {
		sub := dialLive(t, h.base+c.path)
		sub.send([]any{"REQ", "live", map[string]any{"kinds": []int{c.kind}, "limit": 0}})
		time.Sleep(100 * time.Millisecond)

		ev := nostr.Event{Kind: c.kind, CreatedAt: nostr.Now(), Content: fmt.Sprintf("new %d", i), Tags: nostr.Tags{{"p", h.owner}}}
		ev.Sign(h.ownerSK)
		writer := dialLive(t, h.base+c.path)
		ok, msg := writer.publish(ev)
		if !ok && strings.HasPrefix(msg, "auth-required") {
			if !writer.auth(h.ownerSK, h.base+c.path) {
				t.Fatalf("%s: the owner's AUTH was not taken", c.path)
			}
			ok, msg = writer.publish(ev)
		}
		if !ok {
			t.Fatalf("%s: the owner's write was refused: %q", c.path, msg)
		}
		if got := sub.gotEvent(time.Second); got != c.wantEvent {
			t.Errorf("%s, no AUTH, live-only REQ: got the event %v, want %v", c.path, got, c.wantEvent)
		}
	}
}
