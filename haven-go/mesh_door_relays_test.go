package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/barrydeen/haven/pkg/wot"
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

// inboxChallenge gets an AUTH challenge on a mesh /inbox connection: a gift
// wrap from a key outside the web of trust is refused with auth-required,
// and the relay sends its challenge.
func (m *meshWS) inboxChallenge(owner string) string {
	m.t.Helper()
	wrap := nostr.Event{Kind: nostr.KindGiftWrap, CreatedAt: nostr.Now(), Content: "probe", Tags: nostr.Tags{{"p", owner}}}
	wrap.Sign(nostr.GeneratePrivateKey())
	if ok, msg := m.publish(wrap); ok || !strings.HasPrefix(msg, "auth-required") {
		m.t.Fatalf("probe gift wrap: ok %v, %q", ok, msg)
	}
	if m.challenge == "" {
		m.next("AUTH")
	}
	return m.challenge
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

// The box's engine reads its mesh npub from the file when an AUTH comes:
// one nv-mesh wrote after the engine started counts (Tron's low on #1966).
func TestMeshAuthReadsTheNpubFileLate(t *testing.T) {
	h := startHaven(t)
	setHostEnv("HAVEN_MESH_NPUB", "")
	file := t.TempDir() + "/npub"
	setHostEnv("HAVEN_MESH_NPUB_FILE", file)
	t.Cleanup(func() { setHostEnv("HAVEN_MESH_NPUB_FILE", "") })
	door := startMeshDoor(t)
	pk, _ := nostr.GetPublicKey(nostr.GeneratePrivateKey())
	npub, _ := nip19.EncodePublicKey(pk)
	pinned := "ws://" + npub + ".fips/inbox"

	ws := dialDoor(t, door, "/inbox")
	if ws.auth(ws.inboxChallenge(h.owner), h.ownerSK, pinned) {
		t.Fatal("AUTH taken before the npub file existed")
	}
	if err := os.WriteFile(file, []byte(npub+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	ws = dialDoor(t, door, "/inbox")
	if !ws.auth(ws.inboxChallenge(h.owner), h.ownerSK, pinned) {
		t.Fatal("AUTH not taken once the npub file was written")
	}
}

// With no mesh npub handed over, no AUTH over the mesh can succeed.
func TestMeshDoorAuthFailsClosedWithoutMeshNpub(t *testing.T) {
	h := startHaven(t)
	setHostEnv("HAVEN_MESH_NPUB", "")
	door := startMeshDoor(t)
	ws := dialDoor(t, door, "/inbox")
	challenge := ws.inboxChallenge(h.owner)
	pk, _ := nostr.GetPublicKey(nostr.GeneratePrivateKey())
	someNpub, _ := nip19.EncodePublicKey(pk)
	for _, relay := range []string{h.base + "/inbox", "ws://" + someNpub + ".fips/inbox", "", "ws://mesh-npub-unknown.invalid/inbox"} {
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

	// AUTHed as a web of trust member (a follow, with their own key: the
	// account key is never used on the mesh): the gift wrap is taken, and the
	// /inbox still can't be read over the mesh, by them or anyone.
	friendSK := nostr.GeneratePrivateKey()
	friend, _ := nostr.GetPublicKey(friendSK)
	wot.MarkReady(wot.NewCycle(), stubWot{members: map[string]bool{h.owner: true, friend: true}})
	ws = dialDoor(t, door, "/inbox")
	if _, closed := ws.req("r", nostr.Filter{Kinds: []int{nostr.KindGiftWrap}}); !strings.Contains(closed, "only takes incoming") {
		t.Fatalf("an /inbox read over the mesh closed with %q", closed)
	}
	if !ws.auth(ws.inboxChallenge(h.owner), friendSK, pinned) {
		t.Fatal("the follow's pinned AUTH was not taken")
	}
	wrap2 := nostr.Event{Kind: nostr.KindGiftWrap, CreatedAt: nostr.Now(), Content: "sealed 2", Tags: nostr.Tags{{"p", h.owner}}}
	wrap2.Sign(stranger)
	if ok, msg := ws.publish(wrap2); !ok {
		t.Fatalf("a gift wrap from a follow over the mesh was refused: %q", msg)
	}
	if evs, closed := ws.req("s", nostr.Filter{Kinds: []int{nostr.KindGiftWrap}}); len(evs) != 0 || closed == "" {
		t.Fatalf("an AUTHed /inbox read over the mesh: %d events, closed %q", len(evs), closed)
	}
}

// gotEvent reads frames for a while and reports whether an EVENT came.
func (m *meshWS) gotEvent(wait time.Duration) bool {
	m.t.Helper()
	deadline := time.Now().Add(wait)
	for time.Now().Before(deadline) {
		_ = m.c.SetReadDeadline(deadline)
		_, msg, err := m.c.ReadMessage()
		if err != nil {
			return false
		}
		var arr []json.RawMessage
		if json.Unmarshal(msg, &arr) == nil && len(arr) > 0 && str(arr[0]) == "EVENT" {
			return true
		}
	}
	return false
}

func dialURL(t *testing.T, url string) *meshWS {
	t.Helper()
	c, _, err := websocket.DefaultDialer.Dial(url, nil)
	if err != nil {
		t.Fatalf("websocket %s: %v", url, err)
	}
	t.Cleanup(func() { c.Close() })
	return &meshWS{t: t, c: c}
}

// Tron's must-fix on #1966: a live-only REQ ("limit":0) returned before
// every read gate (khatru responding.go), so with no AUTH it got the owner's
// new private and chat events, over the mesh and directly. Six cells.
func TestLiveOnlyREQFacesTheReadGates(t *testing.T) {
	h := startHaven(t)
	withMeshNpub(t)
	door := startMeshDoor(t)
	cells := []struct {
		path      string
		mesh      bool
		kind      int
		wantEvent bool
	}{
		{"/private", true, 1, false},
		{"/private", false, 1, false},
		{"/chat", true, nostr.KindGiftWrap, false},
		{"/chat", false, nostr.KindGiftWrap, false},
		{"/inbox", true, nostr.KindGiftWrap, false},
		{"/inbox", false, nostr.KindGiftWrap, true}, // /inbox reads are open over https
	}
	for i, c := range cells {
		var sub *meshWS
		if c.mesh {
			conn, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(door, "http")+c.path, nil)
			if err != nil {
				if c.wantEvent {
					t.Fatalf("%s over the mesh: %v", c.path, err)
				}
				continue // not served over the mesh at all (/chat, /private)
			}
			t.Cleanup(func() { conn.Close() })
			sub = &meshWS{t: t, c: conn}
		} else {
			sub = dialURL(t, h.base+c.path)
		}
		// A live-only filter for the route's kind (an empty one is refused
		// where empty filters are, live or not).
		sub.send([]any{"REQ", "live", map[string]any{"kinds": []int{c.kind}, "limit": 0}})
		time.Sleep(100 * time.Millisecond)

		ev := nostr.Event{Kind: c.kind, CreatedAt: nostr.Now(), Content: fmt.Sprintf("new %d", i), Tags: nostr.Tags{{"p", h.owner}}}
		ev.Sign(h.ownerSK)
		writer := dialURL(t, h.base+c.path)
		ok, msg := writer.publish(ev)
		if !ok && strings.HasPrefix(msg, "auth-required") {
			if writer.challenge == "" {
				writer.next("AUTH")
			}
			if !writer.auth(writer.challenge, h.ownerSK, h.base+c.path) {
				t.Fatalf("%s: the owner's direct AUTH was not taken", c.path)
			}
			ok, msg = writer.publish(ev)
		}
		if !ok {
			t.Fatalf("%s: the owner's write was refused: %q", c.path, msg)
		}
		if got := sub.gotEvent(time.Second); got != c.wantEvent {
			t.Errorf("%s over the mesh %v, no AUTH, live-only REQ: got the event %v, want %v", c.path, c.mesh, got, c.wantEvent)
		}
	}
}

// Logen's pick B for the mesh door (2026-11-12): over the mesh it takes
// incoming DMs only, and nothing there needs the account key. A mesh read of
// /inbox, /chat or /private is refused, even AUTHed as the owner with the
// pinned address; over https nothing changes.
func TestMeshDoorRefusesInboxChatPrivateReads(t *testing.T) {
	h := startHaven(t)
	npub := withMeshNpub(t)
	door := startMeshDoor(t)
	ctx := context.Background()
	for _, c := range []struct {
		path string
		db   DBBackend
		kind int
	}{{"/inbox", inboxDB, nostr.KindGiftWrap}, {"/chat", chatDB, nostr.KindGiftWrap}, {"/private", privateDB, 1}} {
		ev := nostr.Event{Kind: c.kind, CreatedAt: nostr.Now(), Content: "stored", Tags: nostr.Tags{{"p", h.owner}}}
		ev.Sign(h.ownerSK)
		if err := c.db.SaveEvent(ctx, &ev); err != nil {
			t.Fatal(err)
		}
		f := nostr.Filter{Kinds: []int{c.kind}}

		// Over the mesh: no websocket at all, or a REQ that is refused,
		// with or without the owner's pinned AUTH.
		conn, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(door, "http")+c.path, nil)
		if err == nil {
			ws := &meshWS{t: t, c: conn}
			t.Cleanup(func() { conn.Close() })
			if evs, closed := ws.req("anon", f); len(evs) != 0 || closed == "" {
				t.Errorf("%s over the mesh, no AUTH: %d events, closed %q", c.path, len(evs), closed)
			}
			challenge := ws.challenge
			if challenge == "" {
				challenge = ws.inboxChallenge(h.owner)
			}
			ws.auth(challenge, h.ownerSK, "ws://"+npub+".fips"+c.path)
			if evs, closed := ws.req("owner", f); len(evs) != 0 || closed == "" {
				t.Errorf("%s over the mesh, AUTHed as the owner: %d events, closed %q", c.path, len(evs), closed)
			}
			ws.send([]any{"REQ", "live", map[string]any{"kinds": []int{c.kind}, "limit": 0}})
			if closed := str(ws.next("CLOSED", "EOSE")[0]); closed != "CLOSED" {
				t.Errorf("%s over the mesh: a live-only REQ was not refused", c.path)
			}
		}

		// Over https, as before: the owner AUTHed reads it.
		direct := dialURL(t, h.base+c.path)
		if evs, closed := direct.req("d", f); closed == "" && len(evs) == 1 && c.path == "/inbox" {
			continue // /inbox reads are open over https
		}
		if direct.challenge == "" {
			direct.next("AUTH")
		}
		if !direct.auth(direct.challenge, h.ownerSK, h.base+c.path) {
			t.Fatalf("%s: the owner's https AUTH was not taken", c.path)
		}
		if evs, closed := direct.req("d2", f); closed != "" || len(evs) != 1 {
			t.Errorf("%s over https, AUTHed as the owner: %d events, closed %q", c.path, len(evs), closed)
		}
	}
}
