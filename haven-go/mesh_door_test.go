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
	"path/filepath"
	"runtime"
	"strings"
	"sync"
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
		Content:   nostr.GeneratePrivateKey(), // distinct id per call, like a real per-send signature
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
	h := startHaven(t)
	door := startMeshDoor(t)
	auth := blossomUploadAuth(t, h.ownerSK, []byte("x"))
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
	if got := status(fmt.Sprintf("PUT /upload HTTP/1.1\r\nHost: x\r\nAuthorization: %s\r\nContent-Length: %d\r\n\r\n", auth, meshMaxUploadBytes+1)); !strings.Contains(got, " 413 ") {
		t.Errorf("oversize upload: %q, want 413", got)
	}
	if got := status("PUT /upload HTTP/1.1\r\nHost: x\r\nAuthorization: " + auth + "\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"); !strings.Contains(got, " 411 ") {
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
	prevConfig, prevPool := config, pool
	t.Cleanup(func() { config, pool = prevConfig, prevPool })
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	pool = nostr.NewSimplePool(ctx)

	sk := nostr.GeneratePrivateKey()
	pk, _ := nostr.GetPublicKey(sk)
	config.WhitelistedPubKeys = map[string]struct{}{pk: {}}
	dead, _ := net.Listen("tcp", "127.0.0.1:0")
	deadURL := "ws://" + dead.Addr().String()
	dead.Close()
	config.BlastrRelays = []string{deadURL}
	config.BlastrTimeoutSeconds = 1

	ev := nostr.Event{Kind: 1, CreatedAt: nostr.Now(), Content: "kiosk offline"}
	ev.Sign(sk)
	blastOrKeep(ctx, openBlastQueue(blastPendingFile), &ev)

	q := openBlastQueue(blastPendingFile) // restart: only the file remains
	if s := q.snapshot(); len(s) != 1 || s[0].Event.ID != ev.ID {
		t.Fatalf("queue after restart: %v", s)
	}

	got := make(chan string, 1)
	live := khatru.NewRelay()
	live.StoreEvent = append(live.StoreEvent, func(_ context.Context, e *nostr.Event) error {
		got <- e.ID
		return nil
	})
	srv := httptest.NewServer(live)
	defer srv.Close()

	retryPendingOnce(ctx, q) // still offline: stays queued
	if len(q.snapshot()) != 1 {
		t.Fatal("note dropped while every relay was down")
	}

	config.BlastrRelays = []string{"ws" + strings.TrimPrefix(srv.URL, "http")}
	retryPendingOnce(ctx, q)
	select {
	case id := <-got:
		if id != ev.ID {
			t.Fatalf("relay got %s", id)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("queued note never reached the relay")
	}
	if s := q.snapshot(); len(s) != 0 {
		t.Fatalf("queue after send: %d left", len(s))
	}
	data, _ := os.ReadFile(blastPendingFile)
	if strings.Contains(string(data), ev.ID) {
		t.Fatal("sent note still on disk")
	}
}

// Age counts from when the note was queued, not its created_at; notes that
// are not this account's (another account's file, tampering) never go out.
func TestBlastQueueAgeAndOwnership(t *testing.T) {
	t.Chdir(t.TempDir())
	prevConfig := config
	t.Cleanup(func() { config = prevConfig })
	sk := nostr.GeneratePrivateKey()
	pk, _ := nostr.GetPublicKey(sk)
	config.WhitelistedPubKeys = map[string]struct{}{pk: {}}
	// Nothing listens here, so a retry that does try leaves the note queued.
	dead, _ := net.Listen("tcp", "127.0.0.1:0")
	config.BlastrRelays = []string{"ws://" + dead.Addr().String()}
	dead.Close()
	config.BlastrTimeoutSeconds = 1
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	prevPool := pool
	pool = nostr.NewSimplePool(ctx)
	t.Cleanup(func() { pool = prevPool })

	oldNote := nostr.Event{Kind: 1, CreatedAt: nostr.Timestamp(time.Now().Add(-30 * 24 * time.Hour).Unix()), Content: "imported"}
	oldNote.Sign(sk)
	stale := nostr.Event{Kind: 1, CreatedAt: nostr.Now(), Content: "queued long ago"}
	stale.Sign(sk)
	foreign := nostr.Event{Kind: 1, CreatedAt: nostr.Now(), Content: "other account"}
	foreign.Sign(nostr.GeneratePrivateKey())
	tampered := nostr.Event{Kind: 1, CreatedAt: nostr.Now(), Content: "signed"}
	tampered.Sign(sk)
	tampered.Content = "changed"

	q := openBlastQueue(blastPendingFile)
	now := time.Now().Unix()
	q.items = []pendingBlast{
		{Event: oldNote, QueuedAt: now},
		{Event: stale, QueuedAt: now - int64(8*24*time.Hour/time.Second)},
		{Event: foreign, QueuedAt: now},
		{Event: tampered, QueuedAt: now},
	}
	retryPendingOnce(ctx, q)
	left := q.snapshot()
	if len(left) != 1 || left[0].Event.ID != oldNote.ID {
		ids := []string{}
		for _, p := range left {
			ids = append(ids, p.Event.Content)
		}
		t.Fatalf("left %v, want only the old-created_at note that was queued just now", ids)
	}
}

// The queue file is bound to the data root it was opened in, so a blast that
// finishes after an account switch (chdir) does not write into the new account.
func TestBlastQueueStaysInItsAccount(t *testing.T) {
	a, b := t.TempDir(), t.TempDir()
	t.Chdir(a)
	q := openBlastQueue(blastPendingFile)
	t.Chdir(b)
	ev := nostr.Event{Kind: 1, CreatedAt: nostr.Now()}
	ev.Sign(nostr.GeneratePrivateKey())
	q.add(&ev)
	if _, err := os.Stat(filepath.Join(b, blastPendingFile)); err == nil {
		t.Fatal("account A's note was written into account B's data root")
	}
	if _, err := os.Stat(filepath.Join(a, blastPendingFile)); err != nil {
		t.Fatal("note not saved in its own account")
	}
}

// Tron's proof: strangers claiming 250 MB uploads with a valid signature made
// khatru allocate before its whitelist ran.
func TestMeshStrangerUploadAllocatesNothing(t *testing.T) {
	startHaven(t)
	door := startMeshDoor(t)
	addr := strings.TrimPrefix(door, "http://")
	const claimed = 250 << 20
	const peers = 8

	runtime.GC()
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	var wg sync.WaitGroup
	for i := 0; i < peers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			conn, err := net.Dial("tcp", addr)
			if err != nil {
				return
			}
			defer conn.Close()
			auth := blossomUploadAuth(t, nostr.GeneratePrivateKey(), []byte("x"))
			fmt.Fprintf(conn, "PUT /upload HTTP/1.1\r\nHost: x\r\nAuthorization: %s\r\nContent-Type: text/plain\r\nContent-Length: %d\r\n\r\n%s", auth, claimed, strings.Repeat("A", 60))
			conn.SetReadDeadline(time.Now().Add(3 * time.Second))
			line, _ := bufio.NewReader(conn).ReadString('\n')
			if !strings.Contains(line, " 403 ") {
				t.Errorf("stranger upload: %q, want 403", line)
			}
		}()
	}
	wg.Wait()
	runtime.ReadMemStats(&after)
	if grew := int64(after.TotalAlloc) - int64(before.TotalAlloc); grew > claimed/4 {
		t.Fatalf("strangers made the kiosk allocate %d MB", grew>>20)
	}
}

// Headers then silence: the mesh server drops the connection.
func TestMeshServerDropsSilentPeers(t *testing.T) {
	saved := meshReadHeaderTimeout
	meshReadHeaderTimeout = 300 * time.Millisecond
	defer func() { meshReadHeaderTimeout = saved }()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	srv := newMeshServer(ln.Addr().String())
	go srv.Serve(ln)
	defer srv.Close()

	conn, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	fmt.Fprint(conn, "GET / HTTP/1.1\r\nHost: x\r\n") // never finishes the headers
	conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	start := time.Now()
	_, err = io.ReadAll(conn)
	if ne, ok := err.(net.Error); ok && ne.Timeout() {
		t.Fatal("silent peer still connected after 3 s")
	}
	if time.Since(start) > 2*time.Second {
		t.Fatal("silent peer held the connection too long")
	}
}

// One upload at a time: a second owner upload waits its turn (503 + Retry-After).
func TestMeshOneUploadAtATime(t *testing.T) {
	h := startHaven(t)
	door := startMeshDoor(t)
	meshUploadSlots <- struct{}{} // an upload is in progress
	defer func() { <-meshUploadSlots }()
	body := []byte("second photo")
	r, _ := http.NewRequest(http.MethodPut, door+"/upload", bytes.NewReader(body))
	r.Header.Set("Authorization", blossomUploadAuth(t, h.ownerSK, body))
	resp, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusServiceUnavailable || resp.Header.Get("Retry-After") == "" {
		t.Fatalf("second upload: %d, want 503 with Retry-After", resp.StatusCode)
	}
}

func signedUploadAuth(t *testing.T, sk string, body []byte, expires time.Time) string {
	t.Helper()
	sum := sha256.Sum256(body)
	ev := nostr.Event{Kind: 24242, CreatedAt: nostr.Now(), Tags: nostr.Tags{
		{"t", "upload"}, {"x", hex.EncodeToString(sum[:])}, {"expiration", fmt.Sprint(expires.Unix())},
	}}
	ev.Sign(sk)
	j, _ := json.Marshal(ev)
	return "Nostr " + base64.StdEncoding.EncodeToString(j)
}

// Tron round 2: one owner auth (a public mirror holds one for its hour)
// replayed from eight connections claiming 250 MB and sending 60 bytes.
func TestMeshReplayedAuthAllocatesNothing(t *testing.T) {
	saved := meshIdleRead
	meshIdleRead = 500 * time.Millisecond
	defer func() { meshIdleRead = saved }()
	h := startHaven(t)
	door := startMeshDoor(t)
	addr := strings.TrimPrefix(door, "http://")
	const claimed = 250 << 20
	auth := blossomUploadAuth(t, h.ownerSK, []byte("x"))

	runtime.GC()
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			conn, err := net.Dial("tcp", addr)
			if err != nil {
				return
			}
			defer conn.Close()
			fmt.Fprintf(conn, "PUT /upload HTTP/1.1\r\nHost: x\r\nAuthorization: %s\r\nContent-Length: %d\r\n\r\n%s", auth, claimed, strings.Repeat("A", 60))
			conn.SetReadDeadline(time.Now().Add(5 * time.Second))
			line, _ := bufio.NewReader(conn).ReadString('\n')
			if line == "" {
				t.Error("a stalled upload still held its connection after 5 s")
			}
		}()
	}
	wg.Wait()
	runtime.ReadMemStats(&after)
	if grew := int64(after.TotalAlloc) - int64(before.TotalAlloc); grew > 32<<20 {
		t.Fatalf("claimed sizes made the kiosk allocate %d MB", grew>>20)
	}
}

func TestMeshUploadAuthBinding(t *testing.T) {
	h := startHaven(t)
	door := startMeshDoor(t)
	put := func(auth string, body []byte) int {
		r, _ := http.NewRequest(http.MethodPut, door+"/upload", bytes.NewReader(body))
		r.Header.Set("Authorization", auth)
		resp, err := http.DefaultClient.Do(r)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	a, b := []byte("blob a"), []byte("blob b")

	if code := put(blossomUploadAuth(t, h.ownerSK, a), b); code != http.StatusForbidden {
		t.Errorf("auth for another blob: %d, want 403", code)
	}
	expired := signedUploadAuth(t, h.ownerSK, a, time.Now().Add(-time.Minute))
	if code := put(expired, a); code != http.StatusForbidden {
		t.Errorf("expired auth: %d, want 403", code)
	}
	once := blossomUploadAuth(t, h.ownerSK, a)
	if code := put(once, a); code != http.StatusOK {
		t.Fatalf("first use (control): %d, want 200", code)
	}
	if code := put(once, a); code != http.StatusConflict {
		t.Errorf("same auth again: %d, want 409 (retry with a new auth)", code)
	}
}

func TestMeshListenerCapAndLifetime(t *testing.T) {
	savedMax, savedLife := meshMaxConns, meshConnMaxLifetime
	meshMaxConns, meshConnMaxLifetime = 2, 400*time.Millisecond
	defer func() { meshMaxConns, meshConnMaxLifetime = savedMax, savedLife }()

	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ln := newMeshListener(raw)
	defer ln.Close()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go io.Copy(io.Discard, c) // hold it open like a quiet peer
		}
	}()
	closedWithin := func(c net.Conn, d time.Duration) bool {
		c.SetReadDeadline(time.Now().Add(d))
		_, err := c.Read(make([]byte, 1))
		ne, timeout := err.(net.Error)
		return err != nil && !(timeout && ne.Timeout())
	}
	var conns []net.Conn
	for i := 0; i < 3; i++ {
		c, err := net.Dial("tcp", raw.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		defer c.Close()
		conns = append(conns, c)
		time.Sleep(50 * time.Millisecond)
	}
	if closedWithin(conns[0], 100*time.Millisecond) {
		t.Fatal("first connection refused (control)")
	}
	if !closedWithin(conns[2], 200*time.Millisecond) {
		t.Fatal("third connection admitted over the cap")
	}
	if !closedWithin(conns[0], time.Second) {
		t.Fatal("connection outlived meshConnMaxLifetime")
	}
}

// Tron round 3: a real upload costs about the blob twice (the door's chunks,
// then khatru's copy), not the doubling-buffer churn on top.
func TestMeshUploadAllocation(t *testing.T) {
	h := startHaven(t)
	door := startMeshDoor(t)
	body := bytes.Repeat([]byte("v"), 32<<20)
	auth := blossomUploadAuth(t, h.ownerSK, body)
	runtime.GC()
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	if code := meshPut(t, door, auth, body); code != http.StatusOK {
		t.Fatalf("owner upload: %d", code)
	}
	runtime.ReadMemStats(&after)
	// 96 MB expected: the door's chunks, khatru's buffer, and the test's
	// in-memory filesystem copy (the base commit measured 64 without the door's).
	// Doubling-buffer churn or a late EOF (khatru then doubles) pushes it past 150.
	if grew := int64(after.TotalAlloc) - int64(before.TotalAlloc); grew > 100<<20 {
		t.Fatalf("a 32 MB upload allocated %d MB", grew>>20)
	}
}

// A trickle below the minimum rate loses the slot, and the token it used is spent.
func TestMeshSlowUploadDropped(t *testing.T) {
	savedGrace, savedRate := meshRateGrace, meshMinRate
	meshRateGrace, meshMinRate = 200*time.Millisecond, 1<<20
	defer func() { meshRateGrace, meshMinRate = savedGrace, savedRate }()
	h := startHaven(t)
	door := startMeshDoor(t)
	body := bytes.Repeat([]byte("s"), 4<<20)
	auth := blossomUploadAuth(t, h.ownerSK, body)

	conn, err := net.Dial("tcp", strings.TrimPrefix(door, "http://"))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	fmt.Fprintf(conn, "PUT /upload HTTP/1.1\r\nHost: x\r\nAuthorization: %s\r\nContent-Length: %d\r\n\r\n", auth, len(body))
	start := time.Now()
	for i := 0; i < 20 && time.Since(start) < 3*time.Second; i++ {
		if _, err := conn.Write(body[i*100 : i*100+100]); err != nil {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	line, _ := bufio.NewReader(conn).ReadString('\n')
	if !strings.Contains(line, " 400 ") {
		t.Fatalf("trickled upload: %q, want 400", line)
	}
	if code := meshPut(t, door, auth, body); code != http.StatusConflict {
		t.Fatalf("same token after a stalled try: %d, want 409", code)
	}
	if code := meshPut(t, door, blossomUploadAuth(t, h.ownerSK, body), body); code != http.StatusOK {
		t.Fatalf("fresh token (control): %d, want 200", code)
	}
}
