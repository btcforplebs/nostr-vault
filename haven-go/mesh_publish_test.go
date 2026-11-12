//go:build !(js && wasm)

package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/fasthttp/websocket"
	"github.com/fiatjaf/khatru"
	"github.com/nbd-wtf/go-nostr"
)

// Sync pick 1 (Logen, 2026-11-12): the vault sends the phone's posts. A
// paired device opens the mesh websocket with its own mesh key's "publish"
// token; on that connection, and only there, a fresh owner note the vault
// now holds is blasted, and every other answer is OK false so the phone
// sends it itself. Strangers on the mesh door still never make the vault
// blast anything, old or new. All keys are throwaway.

// dialDoorAs opens a mesh websocket on path with an Authorization header
// (none when auth is ""); it returns the HTTP status when the upgrade is
// refused.
func dialDoorAs(t *testing.T, door, path, auth string) (*meshWS, int) {
	t.Helper()
	h := http.Header{}
	if auth != "" {
		h.Set("Authorization", auth)
	}
	c, resp, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(door, "http")+path, h)
	if err != nil {
		if resp != nil {
			return nil, resp.StatusCode
		}
		t.Fatalf("mesh websocket %s: %v", path, err)
	}
	t.Cleanup(func() { c.Close() })
	return &meshWS{t: t, c: c}, 0
}

// startPublishHaven is startHaven in a temp dir (the blast queue file) with
// a live pool for the blast.
func startPublishHaven(t *testing.T) *havenUnderTest {
	t.Helper()
	t.Chdir(t.TempDir())
	prevPool := pool
	ctx, cancel := context.WithCancel(context.Background())
	pool = nostr.NewSimplePool(ctx)
	t.Cleanup(func() { cancel(); pool = prevPool })
	h := startHaven(t)
	config.OwnerPubKey = h.owner
	return h
}

// publishBlastTarget points the vault's blast at a relay that records what
// it is sent.
func publishBlastTarget(t *testing.T) *sync.Map {
	t.Helper()
	url, _, ids := recordingRelay(t)
	config.BlastrRelays = []string{url}
	config.BlastrTimeoutSeconds = 1
	return ids
}

func waitBlasted(ids *sync.Map, id string, wait time.Duration) bool {
	deadline := time.Now().Add(wait)
	for time.Now().Before(deadline) {
		if _, ok := ids.Load(id); ok {
			return true
		}
		time.Sleep(20 * time.Millisecond)
	}
	return false
}

func TestMeshPublishForMeBlastsFreshNotesOfAPairedDevice(t *testing.T) {
	h := startPublishHaven(t)
	blasted := publishBlastTarget(t)
	door := startMeshDoor(t)
	vault, phone := newTestKey(t), newTestKey(t)
	pairMeshDevices(t, vault, phone)

	ws, code := dialDoorAs(t, door, "/", deviceBlobAuth(t, phone, "publish", "", vault.pk, time.Now().Add(4*time.Minute)))
	if code != 0 {
		t.Fatalf("paired publish connection refused: %d", code)
	}
	note := nostr.Event{Kind: 1, CreatedAt: nostr.Now(), Content: "posted on the phone, sent by the vault"}
	note.Sign(h.ownerSK)
	if ok, msg := ws.publish(note); !ok {
		t.Fatalf("fresh note on a publish connection: OK false %q, want the vault to take it", msg)
	}
	if !waitBlasted(blasted, note.ID, 5*time.Second) {
		t.Fatal("the vault confirmed a fresh note from a paired device but did not blast it")
	}

	// The same note again: the vault already holds it, so it does not
	// confirm (the phone must not count it as sent by the vault).
	if ok, msg := ws.publish(note); ok || !strings.HasPrefix(msg, "duplicate:") {
		t.Errorf("re-sent note: ok %v %q, want OK false duplicate:", ok, msg)
	}
}

// Old notes are never re-blasted, not even for a paired device: the vault
// refuses them on a publish connection and the phone sends them itself.
func TestMeshPublishForMeRefusesOldNotes(t *testing.T) {
	h := startPublishHaven(t)
	blasted := publishBlastTarget(t)
	door := startMeshDoor(t)
	vault, phone := newTestKey(t), newTestKey(t)
	pairMeshDevices(t, vault, phone)

	ws, code := dialDoorAs(t, door, "/", deviceBlobAuth(t, phone, "publish", "", vault.pk, time.Now().Add(4*time.Minute)))
	if code != 0 {
		t.Fatalf("paired publish connection refused: %d", code)
	}
	old := nostr.Event{Kind: 1, CreatedAt: nostr.Now() - 3600, Content: "an hour old"}
	old.Sign(h.ownerSK)
	if ok, msg := ws.publish(old); ok || !strings.HasPrefix(msg, "blocked:") {
		t.Errorf("old note on a publish connection: ok %v %q, want OK false blocked:", ok, msg)
	}
	stranger := nostr.Event{Kind: 1, CreatedAt: nostr.Now(), Content: "not the owner's"}
	stranger.Sign(nostr.GeneratePrivateKey())
	if ok, _ := ws.publish(stranger); ok {
		t.Error("a non-owner note was taken on a publish connection")
	}
	ephemeral := nostr.Event{Kind: 20001, CreatedAt: nostr.Now(), Content: "ephemeral"}
	ephemeral.Sign(h.ownerSK)
	if ok, msg := ws.publish(ephemeral); ok {
		t.Errorf("ephemeral event confirmed on a publish connection (%q): the vault never blasts those", msg)
	}
	if waitBlasted(blasted, old.ID, 1500*time.Millisecond) {
		t.Error("an old note was re-blasted for a paired device")
	}
}

// A stranger on the mesh door cannot make the vault blast: not an old owner
// note it replays, not a fresh one, not with its own key's publish token,
// not with a token for another vault, and not by replaying the phone's.
func TestMeshPublishForMeRefusesStrangers(t *testing.T) {
	h := startPublishHaven(t)
	blasted := publishBlastTarget(t)
	door := startMeshDoor(t)
	vault, phone, stranger, otherVault := newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t)
	pairMeshDevices(t, vault, phone)
	soon := time.Now().Add(4 * time.Minute)

	// The phone's own token, used once, then replayed by someone else.
	phoneToken := deviceBlobAuth(t, phone, "publish", "", vault.pk, soon)
	if _, code := dialDoorAs(t, door, "/", phoneToken); code != 0 {
		t.Fatalf("paired publish connection refused: %d", code)
	}
	if _, code := dialDoorAs(t, door, "/", phoneToken); code != http.StatusConflict {
		t.Errorf("replayed publish token: %d, want 409", code)
	}
	for name, auth := range map[string]string{
		"for another vault": deviceBlobAuth(t, phone, "publish", "", otherVault.pk, soon),
		"an upload token":   deviceBlobAuth(t, phone, "upload", "", vault.pk, soon),
		"expired":           deviceBlobAuth(t, phone, "publish", "", vault.pk, time.Now().Add(-time.Second)),
	} {
		if _, code := dialDoorAs(t, door, "/", auth); code == 0 {
			t.Errorf("publish connection %s was opened", name)
		}
	}

	var sent []string
	try := func(label, auth string, created nostr.Timestamp) {
		ws, code := dialDoorAs(t, door, "/", auth)
		if code != 0 {
			return // refused at the door: nothing can be blasted
		}
		ev := nostr.Event{Kind: 1, CreatedAt: created, Content: "replayed by a stranger: " + label}
		ev.Sign(h.ownerSK)
		ws.publish(ev)
		sent = append(sent, ev.ID)
	}
	try("old, no token", "", nostr.Now()-86400)
	try("fresh, no token", "", nostr.Now())
	try("old, stranger's own publish token", deviceBlobAuth(t, stranger, "publish", "", vault.pk, soon), nostr.Now()-86400)
	try("fresh, stranger's own publish token", deviceBlobAuth(t, stranger, "publish", "", vault.pk, soon), nostr.Now())
	time.Sleep(1500 * time.Millisecond)
	for _, id := range sent {
		if _, ok := blasted.Load(id); ok {
			t.Errorf("a stranger made the vault blast %s", id[:8])
		}
	}
}

// The vault confirms only what it blasts: a replaceable event it does not
// store (it keeps a newer copy) is OK false on a publish connection.
func TestMeshPublishForMeDoesNotConfirmAStaleReplaceable(t *testing.T) {
	sk, pk := withOwner(t)
	db := withOutbox(t)
	relay := khatru.NewRelay()
	var n atomic.Int32
	wireOutboxWrites(relay, db, func(*nostr.Event) { n.Add(1) })
	vault, phone := newTestKey(t), newTestKey(t)
	pairMeshDevices(t, vault, phone)

	newer := &nostr.Event{PubKey: pk, Kind: 0, CreatedAt: nostr.Now(), Content: `{"name":"newer"}`}
	newer.Sign(sk)
	if _, err := relay.AddEvent(connCtx("/"), newer); err != nil {
		t.Fatal(err)
	}
	n.Store(0)
	stale := &nostr.Event{PubKey: pk, Kind: 0, CreatedAt: nostr.Now() - 30, Content: `{"name":"older"}`}
	stale.Sign(sk)
	_, err := relay.AddEvent(publishConnCtx(t, phone, vault), stale)
	if err == nil {
		t.Error("a stale replaceable was confirmed on a publish connection")
	}
	if n.Load() != 0 {
		t.Error("a stale replaceable was blasted")
	}
}

// publishConnCtx is a relay callback context on a mesh websocket admitted on
// phone's publish token for vault.
func publishConnCtx(t *testing.T, phone, vault testKey) context.Context {
	t.Helper()
	r := markMesh(httptest.NewRequest(http.MethodGet, "/", nil))
	r.Header.Set("Upgrade", "websocket")
	r.Header.Set("Authorization", deviceBlobAuth(t, phone, "publish", "", vault.pk, time.Now().Add(4*time.Minute)))
	r, code, why := withMeshDeviceAuth(r)
	if code != 0 {
		t.Fatalf("publish token refused: %d %s", code, why)
	}
	return context.WithValue(context.Background(), 0, &khatru.WebSocket{Request: r})
}

// The phone counts a confirm only on a connection the vault marked as a
// publish connection: its first frame is the publish NOTICE. An older vault,
// or one that has not paired this phone, never sends it, so the phone sends
// the note itself rather than holding it for a vault that will not.
func TestMeshPublishForMeIsAnnounced(t *testing.T) {
	h := startPublishHaven(t)
	_ = h
	door := startMeshDoor(t)
	vault, phone, stranger := newTestKey(t), newTestKey(t), newTestKey(t)
	pairMeshDevices(t, vault, phone)
	soon := time.Now().Add(4 * time.Minute)

	ws, code := dialDoorAs(t, door, "/", deviceBlobAuth(t, phone, "publish", "", vault.pk, soon))
	if code != 0 {
		t.Fatalf("paired publish connection refused: %d", code)
	}
	if msg := ws.next("NOTICE"); str(msg[1]) != meshPublishNotice {
		t.Errorf("first NOTICE %q, want %q", str(msg[1]), meshPublishNotice)
	}

	// An unpaired key's publish token is turned down at the door, at once.
	if _, code := dialDoorAs(t, door, "/", deviceBlobAuth(t, stranger, "publish", "", vault.pk, soon)); code != http.StatusForbidden {
		t.Errorf("unpaired publish token: %d, want 403", code)
	}

	// A plain mesh connection is not announced.
	plain, _ := dialDoorAs(t, door, "/", "")
	plain.send([]any{"REQ", "x", nostr.Filter{Kinds: []int{1}, Limit: 1}})
	if msg := plain.next("NOTICE", "EOSE", "CLOSED"); str(msg[0]) == "NOTICE" {
		t.Errorf("a plain mesh connection got NOTICE %q", str(msg[1]))
	}
}
