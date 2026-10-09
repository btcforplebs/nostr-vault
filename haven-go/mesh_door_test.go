package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/fiatjaf/khatru"
	"github.com/nbd-wtf/go-nostr"
)

func startMeshDoor(t *testing.T) string {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(meshHandler))
	t.Cleanup(srv.Close)
	return srv.URL
}

func blossomUploadAuth(t *testing.T, sk string, body []byte) string {
	t.Helper()
	sum := sha256.Sum256(body)
	ev := nostr.Event{
		Kind:      24242,
		CreatedAt: nostr.Now(),
		Tags: nostr.Tags{
			{"t", "upload"},
			{"x", hex.EncodeToString(sum[:])},
			{"expiration", fmt.Sprint(time.Now().Add(10 * time.Minute).Unix())},
		},
	}
	if err := ev.Sign(sk); err != nil {
		t.Fatal(err)
	}
	j, _ := json.Marshal(ev)
	return "Nostr " + base64.StdEncoding.EncodeToString(j)
}

func meshPut(t *testing.T, door, auth string, body []byte) int {
	t.Helper()
	r, _ := http.NewRequest(http.MethodPut, door+"/upload", bytes.NewReader(body))
	r.Header.Set("Authorization", auth)
	r.Header.Set("Content-Type", "text/plain")
	resp, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	return resp.StatusCode
}

// The owner's other phone can push a blob through the mesh door and read it
// back; anyone else is turned away by the Blossom whitelist.
func TestMeshUploadOwnerOnly(t *testing.T) {
	h := startHaven(t)
	door := startMeshDoor(t)

	body := []byte("photo from the other phone")
	sum := sha256.Sum256(body)
	hash := hex.EncodeToString(sum[:])

	stranger := nostr.GeneratePrivateKey()
	if code := meshPut(t, door, blossomUploadAuth(t, stranger, body), body); code != http.StatusForbidden {
		t.Fatalf("stranger upload: got %d, want 403", code)
	}
	resp, err := http.Get(door + "/" + hash)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode == http.StatusOK {
		t.Fatal("stranger's blob was stored")
	}

	if code := meshPut(t, door, blossomUploadAuth(t, h.ownerSK, body), body); code != http.StatusOK {
		t.Fatalf("owner upload: got %d, want 200", code)
	}
	resp, err = http.Get(door + "/" + hash)
	if err != nil {
		t.Fatal(err)
	}
	got, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK || !bytes.Equal(got, body) {
		t.Fatalf("read back over the mesh: %d %q", resp.StatusCode, got)
	}

	// HEAD /upload answers the pre-flight with the same whitelist.
	check, _ := http.NewRequest(http.MethodHead, door+"/upload", nil)
	check.Header.Set("Authorization", blossomUploadAuth(t, stranger, body))
	check.Header.Set("X-Content-Length", fmt.Sprint(len(body)))
	resp, err = http.DefaultClient.Do(check)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("stranger HEAD /upload: got %d, want 403", resp.StatusCode)
	}
}

// Size is checked before khatru allocates Content-Length bytes.
func TestMeshUploadSizeChecks(t *testing.T) {
	door := startMeshDoor(t)
	addr := strings.TrimPrefix(door, "http://")
	status := func(head string) string {
		conn, err := net.Dial("tcp", addr)
		if err != nil {
			t.Fatal(err)
		}
		defer conn.Close()
		fmt.Fprint(conn, head)
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		line, _ := bufio.NewReader(conn).ReadString('\n')
		return line
	}
	if got := status(fmt.Sprintf("PUT /upload HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n", meshMaxUploadBytes+1)); !strings.Contains(got, " 413 ") {
		t.Errorf("oversize upload: %q, want 413", got)
	}
	if got := status("PUT /upload HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"); !strings.Contains(got, " 411 ") {
		t.Errorf("upload without length: %q, want 411", got)
	}
}

// Over a mesh websocket only owner-signed EVENTs land, and nothing can be
// read. The same relay reached directly is the control.
func TestMeshRelayOwnerEventsOnly(t *testing.T) {
	h := startHaven(t)
	door := startMeshDoor(t)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	mesh, err := nostr.RelayConnect(ctx, "ws"+strings.TrimPrefix(door, "http"))
	if err != nil {
		t.Fatal(err)
	}
	defer mesh.Close()

	note := nostr.Event{Kind: 1, CreatedAt: nostr.Now(), Content: "posted from the other phone"}
	note.Sign(h.ownerSK)
	if err := mesh.Publish(ctx, note); err != nil {
		t.Fatalf("owner note over the mesh: %v", err)
	}

	strangerNote := nostr.Event{Kind: 1, CreatedAt: nostr.Now(), Content: "spam"}
	strangerNote.Sign(nostr.GeneratePrivateKey())
	if err := mesh.Publish(ctx, strangerNote); err == nil || !strings.Contains(err.Error(), "mesh accepts only the owner") {
		t.Fatalf("stranger note over the mesh: %v, want rejected", err)
	}

	if _, reason := req(t, mesh, nostr.Filter{Authors: []string{h.owner}}); !strings.Contains(reason, "no queries over the mesh") {
		t.Fatalf("REQ over the mesh: closed %q, want refused", reason)
	}

	direct := h.connect(t, "")
	evs, reason := req(t, direct, nostr.Filter{Authors: []string{h.owner}})
	if reason != "" || len(evs) != 1 || evs[0].ID != note.ID {
		t.Fatalf("direct REQ (control): %d events, closed %q", len(evs), reason)
	}
}

// Plain GETs off the blob path still 404: no feed page, no NIP-11.
func TestMeshDoorClosedToEverythingElse(t *testing.T) {
	startHaven(t)
	door := startMeshDoor(t)
	for _, c := range []struct{ method, path, accept string }{
		{http.MethodGet, "/", ""},
		{http.MethodGet, "/", "application/nostr+json"},
		{http.MethodPost, "/", ""},
		{http.MethodPut, "/mirror", ""},
		{http.MethodGet, "/list/" + strings.Repeat("ab", 32), ""},
		{http.MethodGet, "/inbox", ""},
	} {
		r, _ := http.NewRequest(c.method, door+c.path, nil)
		if c.accept != "" {
			r.Header.Set("Accept", c.accept)
		}
		resp, err := http.DefaultClient.Do(r)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusNotFound {
			t.Errorf("%s %s (accept %q): got %d, want 404", c.method, c.path, c.accept, resp.StatusCode)
		}
	}
}

func TestMeshConnectionsFaceTheLimiter(t *testing.T) {
	limited := meshAwareConnectionLimiter(func(*http.Request) bool { return true })
	r := httptest.NewRequest(http.MethodGet, "/", nil)
	r.RemoteAddr = "127.0.0.1:5555"
	if limited(r) {
		t.Fatal("owner's own loopback connection was limited (control)")
	}
	if !limited(markMesh(r)) {
		t.Fatal("mesh connection got the loopback free pass")
	}
}

// A note no relay took survives a restart and goes out once a relay answers.
func TestBlastQueueSurvivesRestart(t *testing.T) {
	t.Chdir(t.TempDir())
	prevConfig, prevPool, prevQueue := config, pool, pendingBlasts.snapshot()
	t.Cleanup(func() {
		config, pool = prevConfig, prevPool
		pendingBlasts = blastQueue{loaded: true, events: prevQueue}
	})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	pool = nostr.NewSimplePool(ctx)
	pendingBlasts = blastQueue{}

	dead, _ := net.Listen("tcp", "127.0.0.1:0")
	deadURL := "ws://" + dead.Addr().String()
	dead.Close()
	config.BlastrRelays = []string{deadURL}
	config.BlastrTimeoutSeconds = 1

	ev := nostr.Event{Kind: 1, CreatedAt: nostr.Now(), Content: "kiosk offline"}
	ev.Sign(nostr.GeneratePrivateKey())
	blastOrKeep(ctx, &ev)

	pendingBlasts = blastQueue{} // restart: only the file remains
	if q := pendingBlasts.snapshot(); len(q) != 1 || q[0].ID != ev.ID {
		t.Fatalf("queue after restart: %v", q)
	}

	got := make(chan string, 1)
	live := khatru.NewRelay()
	live.StoreEvent = append(live.StoreEvent, func(_ context.Context, e *nostr.Event) error {
		got <- e.ID
		return nil
	})
	srv := httptest.NewServer(live)
	defer srv.Close()

	retryPendingOnce(ctx) // still offline: stays queued
	if len(pendingBlasts.snapshot()) != 1 {
		t.Fatal("note dropped while every relay was down")
	}

	config.BlastrRelays = []string{"ws" + strings.TrimPrefix(srv.URL, "http")}
	retryPendingOnce(ctx)
	select {
	case id := <-got:
		if id != ev.ID {
			t.Fatalf("relay got %s", id)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("queued note never reached the relay")
	}
	if q := pendingBlasts.snapshot(); len(q) != 0 {
		t.Fatalf("queue after send: %d left", len(q))
	}
	data, _ := os.ReadFile(blastPendingPath)
	if strings.Contains(string(data), ev.ID) {
		t.Fatal("sent note still on disk")
	}
}
