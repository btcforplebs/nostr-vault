package main

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/fasthttp/websocket"
	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip19"
)

// Sync rework M2: the mesh door serves /inbox, /chat and /private with the
// https rules, NIP-42 AUTH pinned to this vault's mesh address, and the mesh
// caps. Driven through the whole relay and the real door.

type meshWS struct {
	t         *testing.T
	c         *websocket.Conn
	challenge string // the latest AUTH challenge seen, whatever next was waiting for
}

func dialDoor(t *testing.T, door, path string) *meshWS {
	t.Helper()
	c, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(door, "http")+path, nil)
	if err != nil {
		t.Fatalf("mesh websocket %s: %v", path, err)
	}
	t.Cleanup(func() { c.Close() })
	return &meshWS{t: t, c: c}
}

func (m *meshWS) send(v any) {
	m.t.Helper()
	b, _ := json.Marshal(v)
	if err := m.c.WriteMessage(websocket.TextMessage, b); err != nil {
		m.t.Fatal(err)
	}
}

// next reads frames until one whose label is in labels.
func (m *meshWS) next(labels ...string) []json.RawMessage {
	m.t.Helper()
	_ = m.c.SetReadDeadline(time.Now().Add(5 * time.Second))
	for {
		_, msg, err := m.c.ReadMessage()
		if err != nil {
			m.t.Fatalf("waiting for %v: %v", labels, err)
		}
		var arr []json.RawMessage
		if json.Unmarshal(msg, &arr) != nil || len(arr) == 0 {
			continue
		}
		var label string
		_ = json.Unmarshal(arr[0], &label)
		if label == "AUTH" && len(arr) > 1 {
			m.challenge = str(arr[1])
		}
		for _, l := range labels {
			if l == label {
				return arr
			}
		}
	}
}

func str(raw json.RawMessage) string {
	var s string
	_ = json.Unmarshal(raw, &s)
	return s
}

// auth answers the connection's challenge as sk, naming relay; it reports
// whether the vault took it.
func (m *meshWS) auth(challenge, sk, relay string) bool {
	m.t.Helper()
	ev := nostr.Event{Kind: nostr.KindClientAuthentication, CreatedAt: nostr.Now(),
		Tags: nostr.Tags{{"relay", relay}, {"challenge", challenge}}}
	ev.Sign(sk)
	m.send([]any{"AUTH", ev})
	ok := m.next("OK")
	var accepted bool
	_ = json.Unmarshal(ok[2], &accepted)
	return accepted
}

// req sends a REQ and returns the events and the CLOSED reason ("" on EOSE).
func (m *meshWS) req(id string, f nostr.Filter) ([]nostr.Event, string) {
	m.t.Helper()
	m.send([]any{"REQ", id, f})
	var evs []nostr.Event
	for {
		msg := m.next("EVENT", "EOSE", "CLOSED")
		switch str(msg[0]) {
		case "EVENT":
			var ev nostr.Event
			_ = json.Unmarshal(msg[2], &ev)
			evs = append(evs, ev)
		case "EOSE":
			return evs, ""
		case "CLOSED":
			return evs, str(msg[2])
		}
	}
}

func (m *meshWS) publish(ev nostr.Event) (bool, string) {
	m.t.Helper()
	m.send([]any{"EVENT", ev})
	ok := m.next("OK")
	var accepted bool
	_ = json.Unmarshal(ok[2], &accepted)
	return accepted, str(ok[3])
}

// withMeshNpub sets this vault's mesh npub (HAVEN_MESH_NPUB) for the test.
func withMeshNpub(t *testing.T) string {
	t.Helper()
	pk, _ := nostr.GetPublicKey(nostr.GeneratePrivateKey())
	npub, _ := nip19.EncodePublicKey(pk)
	setHostEnv("HAVEN_MESH_NPUB", npub)
	t.Cleanup(func() { setHostEnv("HAVEN_MESH_NPUB", "") })
	return npub
}

// No private or chat data over the mesh without AUTH as the right key, with
// the relay tag pinned to this vault's mesh address.
func TestMeshDoorPrivateAndChatNeedPinnedAuth(t *testing.T) {
	h := startHaven(t)
	npub := withMeshNpub(t)
	door := startMeshDoor(t)
	ctx := context.Background()
	stranger := nostr.GeneratePrivateKey()

	for _, c := range []struct {
		path string
		db   DBBackend
		kind int
	}{{"/private", privateDB, 1}, {"/chat", chatDB, nostr.KindGiftWrap}} {
		note := nostr.Event{Kind: c.kind, CreatedAt: nostr.Now(), Content: "only mine",
			Tags: nostr.Tags{{"p", h.owner}}}
		note.Sign(h.ownerSK)
		if err := c.db.SaveEvent(ctx, &note); err != nil {
			t.Fatal(err)
		}
		f := nostr.Filter{Authors: []string{h.owner}}
		pinned := "ws://" + npub + ".fips" + c.path

		// No AUTH: refused.
		ws := dialDoor(t, door, c.path)
		challenge := str(ws.next("AUTH")[1])
		if evs, closed := ws.req("a", f); len(evs) != 0 || !strings.HasPrefix(closed, "auth-required") {
			t.Fatalf("%s without AUTH: %d events, closed %q", c.path, len(evs), closed)
		}
		// The owner's AUTH naming another relay (the Host-derived or local
		// address a forwarding relay would get signed): not taken.
		for _, other := range []string{h.base + c.path, "ws://" + npub + ".fips/other", "wss://attacker.example" + c.path} {
			if ws.auth(challenge, h.ownerSK, other) {
				t.Fatalf("%s: AUTH naming %s was taken", c.path, other)
			}
		}
		if evs, closed := ws.req("b", f); len(evs) != 0 || closed == "" {
			t.Fatalf("%s after a refused AUTH: %d events, closed %q", c.path, len(evs), closed)
		}

		// A stranger's correct AUTH: taken, but it reads nothing.
		ws = dialDoor(t, door, c.path)
		challenge = str(ws.next("AUTH")[1])
		if !ws.auth(challenge, stranger, pinned) {
			t.Fatalf("%s: the stranger's pinned AUTH was not taken", c.path)
		}
		if evs, closed := ws.req("c", f); len(evs) != 0 || closed == "" {
			t.Fatalf("%s as a stranger: %d events, closed %q", c.path, len(evs), closed)
		}

		// The owner's AUTH, pinned: served.
		ws = dialDoor(t, door, c.path)
		challenge = str(ws.next("AUTH")[1])
		if !ws.auth(challenge, h.ownerSK, pinned) {
			t.Fatalf("%s: the owner's pinned AUTH was not taken", c.path)
		}
		if evs, closed := ws.req("d", f); closed != "" || len(evs) != 1 || evs[0].ID != note.ID {
			t.Fatalf("%s as the owner: %d events, closed %q", c.path, len(evs), closed)
		}
		// The mesh caps apply here too: too many filters in one REQ.
		many := make([]any, 0, meshMaxFilters+2)
		many = append(many, "REQ", "e")
		for i := 0; i <= meshMaxFilters; i++ {
			many = append(many, f)
		}
		ws.send(many)
		if closed := str(ws.next("CLOSED")[2]); !strings.Contains(closed, "filters") {
			t.Fatalf("%s: %d filters closed with %q", c.path, meshMaxFilters+1, closed)
		}
	}
}

// With no mesh npub handed over, no AUTH over the mesh can succeed.
func TestMeshDoorAuthFailsClosedWithoutMeshNpub(t *testing.T) {
	h := startHaven(t)
	setHostEnv("HAVEN_MESH_NPUB", "")
	door := startMeshDoor(t)
	ws := dialDoor(t, door, "/private")
	challenge := str(ws.next("AUTH")[1])
	pk, _ := nostr.GetPublicKey(nostr.GeneratePrivateKey())
	someNpub, _ := nip19.EncodePublicKey(pk)
	for _, relay := range []string{h.base + "/private", "ws://" + someNpub + ".fips/private"} {
		if ws.auth(challenge, h.ownerSK, relay) {
			t.Fatalf("AUTH naming %s was taken with no mesh npub", relay)
		}
	}
}

// /inbox over the mesh: gift wraps only, from the web of trust, and read
// only by the vault's own accounts.
func TestMeshDoorInboxGiftWrapsFromTheWebOfTrustOnly(t *testing.T) {
	h := startHaven(t)
	npub := withMeshNpub(t)
	door := startMeshDoor(t)
	pinned := "ws://" + npub + ".fips/inbox"

	// Anything but a gift wrap is refused over the mesh, whoever signed it.
	reply := nostr.Event{Kind: 1, CreatedAt: nostr.Now(), Content: "reply", Tags: nostr.Tags{{"p", h.owner}}}
	reply.Sign(h.ownerSK)
	ws := dialDoor(t, door, "/inbox")
	if ok, msg := ws.publish(reply); ok || !strings.Contains(msg, "gift-wrapped") {
		t.Fatalf("a non-gift-wrap over the mesh: ok %v, %q", ok, msg)
	}

	// A gift wrap from a key outside the web of trust, AUTHed as it: refused.
	stranger := nostr.GeneratePrivateKey()
	wrap := nostr.Event{Kind: nostr.KindGiftWrap, CreatedAt: nostr.Now(), Content: "sealed", Tags: nostr.Tags{{"p", h.owner}}}
	wrap.Sign(stranger)
	if ok, _ := ws.publish(wrap); ok {
		t.Fatal("a gift wrap from outside the web of trust was taken without AUTH")
	}
	if ws.challenge == "" {
		ws.next("AUTH")
	}
	if !ws.auth(ws.challenge, stranger, pinned) {
		t.Fatal("the stranger's pinned AUTH was not taken")
	}
	if ok, _ := ws.publish(wrap); ok {
		t.Fatal("a gift wrap AUTHed as a key outside the web of trust was taken")
	}

	// AUTHed as a web of trust member (the owner): the gift wrap is taken.
	ws = dialDoor(t, door, "/inbox")
	if _, closed := ws.req("r", nostr.Filter{Kinds: []int{nostr.KindGiftWrap}}); !strings.HasPrefix(closed, "auth-required") {
		t.Fatalf("an /inbox read over the mesh without AUTH closed with %q", closed)
	}
	if ws.challenge == "" {
		ws.next("AUTH")
	}
	if !ws.auth(ws.challenge, h.ownerSK, pinned) {
		t.Fatal("the owner's pinned AUTH was not taken")
	}
	wrap2 := nostr.Event{Kind: nostr.KindGiftWrap, CreatedAt: nostr.Now(), Content: "sealed 2", Tags: nostr.Tags{{"p", h.owner}}}
	wrap2.Sign(stranger)
	if ok, msg := ws.publish(wrap2); !ok {
		t.Fatalf("a gift wrap AUTHed as the owner was refused: %q", msg)
	}
	if evs, closed := ws.req("s", nostr.Filter{Kinds: []int{nostr.KindGiftWrap}}); closed != "" || len(evs) != 1 {
		t.Fatalf("the owner's /inbox read over the mesh: %d events, closed %q", len(evs), closed)
	}
}
