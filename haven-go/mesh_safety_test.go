package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/fiatjaf/khatru"
	"github.com/fiatjaf/khatru/blossom"
	"github.com/nbd-wtf/go-nostr"
	"github.com/spf13/afero"
)

func blobHash(c byte) string { return strings.Repeat(string(c), 64) }

// meshCtx is a relay callback context on a mesh websocket (khatru keeps the
// connection under its first context key, the untyped constant 0).
func meshCtx() context.Context {
	return context.WithValue(context.Background(), 0, &khatru.WebSocket{Request: markMesh(httptest.NewRequest(http.MethodGet, "/", nil))})
}

func withOwner(t *testing.T) (sk, pk string) {
	t.Helper()
	sk = nostr.GeneratePrivateKey()
	pk, _ = nostr.GetPublicKey(sk)
	saved := config.WhitelistedPubKeys
	config.WhitelistedPubKeys = map[string]struct{}{pk: {}}
	t.Cleanup(func() { config.WhitelistedPubKeys = saved })
	return sk, pk
}

func withOutbox(t *testing.T) DBBackend {
	t.Helper()
	saved := outboxDB
	t.Cleanup(func() { outboxDB = saved })
	db := newTestBackend(t, "outbox")
	if err := db.Init(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	outboxDB = db
	meshBlobs.reset()
	t.Cleanup(meshBlobs.reset)
	return db
}

// (1) Over the mesh door a stranger reads only blobs a public note names.
// The owner's own app (dynamicRelayHandler) and the owner's signed request
// still read anything.
func TestMeshBlobGetOnlyPubliclyNamed(t *testing.T) {
	sk, pk := withOwner(t)
	db := withOutbox(t)
	posted, private := blobHash('a'), blobHash('b')

	note := nostr.Event{PubKey: pk, Kind: 1, CreatedAt: nostr.Now(), Content: "a photo",
		Tags: nostr.Tags{{"imeta", "url https://blossom.example/" + posted + ".jpg", "x " + posted}}}
	note.Sign(sk)
	if err := db.SaveEvent(context.Background(), &note); err != nil {
		t.Fatal(err)
	}

	savedRelay, savedFs, savedPath := outboxRelay, fs, config.BlossomPath
	t.Cleanup(func() { outboxRelay, fs, config.BlossomPath = savedRelay, savedFs, savedPath })
	outboxRelay, fs, config.BlossomPath = khatru.NewRelay(), afero.NewMemMapFs(), "/blobs/"
	for _, h := range []string{posted, private} {
		if err := afero.WriteFile(fs, config.BlossomPath+h, []byte("blob "+h[:1]), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	index := newTestBackend(t, "blossom")
	if err := index.Init(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(index.Close)
	bs := blossom.New(outboxRelay, "http://vault.example")
	bs.Store = blossom.EventStoreBlobIndexWrapper{Store: index, ServiceURL: bs.ServiceURL}
	bs.LoadBlob = append(bs.LoadBlob, loadBlob)
	guardMeshBlobs(bs)

	mesh := httptest.NewServer(http.HandlerFunc(meshHandler))
	defer mesh.Close()
	own := httptest.NewServer(http.HandlerFunc(dynamicRelayHandler))
	defer own.Close()

	get := func(base, method, hash string, auth string) int {
		req, _ := http.NewRequest(method, base+"/"+hash, nil)
		if auth != "" {
			req.Header.Set("Authorization", "Nostr "+auth)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		return resp.StatusCode
	}

	if got := get(mesh.URL, http.MethodGet, posted, ""); got != 200 {
		t.Errorf("stranger GET of a posted blob: %d, want 200", got)
	}
	for _, m := range []string{http.MethodGet, http.MethodHead} {
		if got := get(mesh.URL, m, private, ""); got != 404 {
			t.Errorf("stranger %s of an unposted blob: %d, want 404", m, got)
		}
	}
	if got := get(own.URL, http.MethodGet, private, ""); got != 200 {
		t.Errorf("owner's app GET of an unposted blob: %d, want 200", got)
	}

	signed := func(signer string) string {
		ev := nostr.Event{Kind: 24242, CreatedAt: nostr.Now(), Content: "get",
			Tags: nostr.Tags{{"t", "get"}, {"x", private}, {"expiration", strconv.FormatInt(time.Now().Add(time.Hour).Unix(), 10)}}}
		ev.Sign(signer)
		j, _ := json.Marshal(ev)
		return base64.StdEncoding.EncodeToString(j)
	}
	if got := get(mesh.URL, http.MethodGet, private, signed(sk)); got != 200 {
		t.Errorf("owner-signed GET over the mesh: %d, want 200", got)
	}
	if got := get(mesh.URL, http.MethodGet, private, signed(nostr.GeneratePrivateKey())); got != 404 {
		t.Errorf("stranger-signed GET over the mesh: %d, want 404", got)
	}

	// A note stored later names its media at once, without waiting for the TTL.
	later := blobHash('c')
	afero.WriteFile(fs, config.BlossomPath+later, []byte("blob c"), 0o644)
	if got := get(mesh.URL, http.MethodGet, later, ""); got != 404 {
		t.Fatalf("unposted %s: %d, want 404", later[:4], got)
	}
	note2 := nostr.Event{PubKey: pk, Kind: 1, CreatedAt: nostr.Now(), Content: "https://x.example/" + later + ".png"}
	note2.Sign(sk)
	noteStoredForMeshBlobs(context.Background(), &note2)
	if got := get(mesh.URL, http.MethodGet, later, ""); got != 200 {
		t.Errorf("blob of a note stored after the index was read: %d, want 200", got)
	}
}

// (1) The index pages past the eventstore's per-query limit.
func TestMeshBlobIndexReadsEveryPage(t *testing.T) {
	sk, pk := withOwner(t)
	db := withOutbox(t)
	ctx := context.Background()
	total := meshBlobPageSize + 250
	base := nostr.Now() - nostr.Timestamp(total)
	var first string
	for i := 0; i < total; i++ {
		h := fmt.Sprintf("%064x", i+1)
		if i == 0 {
			first = h // the oldest note: only the last page holds it
		}
		ev := nostr.Event{PubKey: pk, Kind: 1, CreatedAt: base + nostr.Timestamp(i), Tags: nostr.Tags{{"x", h}}}
		ev.Sign(sk)
		if err := db.SaveEvent(ctx, &ev); err != nil {
			t.Fatal(err)
		}
	}
	if !meshBlobs.has(ctx, first) {
		t.Error("the oldest note's blob was not indexed: paging stopped early")
	}
}

// (2) Only what the store now holds is blasted, and nothing sent over the
// mesh door.
func TestBlastOnlyStoredAndNotFromTheMesh(t *testing.T) {
	sk, pk := withOwner(t)
	db := withOutbox(t)
	ctx := context.Background()

	var blasted []string
	hook := newBlastStored(outboxHolds, func(ev *nostr.Event) { blasted = append(blasted, ev.ID) })

	newer := nostr.Event{PubKey: pk, Kind: 0, CreatedAt: 2000, Content: `{"name":"new"}`}
	newer.Sign(sk)
	older := nostr.Event{PubKey: pk, Kind: 0, CreatedAt: 1000, Content: `{"name":"old"}`}
	older.Sign(sk)

	if err := db.ReplaceEvent(ctx, &newer); err != nil {
		t.Fatal(err)
	}
	hook(ctx, &newer)
	// The store keeps the newer copy and returns nil for the older one.
	if err := db.ReplaceEvent(ctx, &older); err != nil {
		t.Fatal(err)
	}
	if outboxHolds(ctx, older.ID) {
		t.Fatal("test setup: the store took the older replaceable")
	}
	hook(ctx, &older)

	note := nostr.Event{PubKey: pk, Kind: 1, CreatedAt: nostr.Now(), Content: "from the mesh"}
	note.Sign(sk)
	if err := db.SaveEvent(ctx, &note); err != nil {
		t.Fatal(err)
	}
	hook(meshCtx(), &note)

	if len(blasted) != 1 || blasted[0] != newer.ID {
		t.Errorf("blasted %v, want only the newer kind 0 %s", blasted, newer.ID[:8])
	}
}

// (3) A reader that stops taking bytes loses the blob response in seconds;
// one that keeps reading gets all of it.
func TestMeshBlobResponseDropsAStalledReader(t *testing.T) {
	savedIdle, savedGrace := meshIdleWrite, meshSendGrace
	meshIdleWrite, meshSendGrace = 300*time.Millisecond, 300*time.Millisecond
	t.Cleanup(func() { meshIdleWrite, meshSendGrace = savedIdle, savedGrace })

	const size = 64 << 20
	done := make(chan error, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fw := newMeshSendFloorWriter(w)
		w.Header().Set("Content-Length", strconv.Itoa(size))
		buf := make([]byte, 1<<20)
		var err error
		for sent := 0; sent < size && err == nil; sent += len(buf) {
			_, err = fw.Write(buf)
		}
		done <- err
	}))
	defer srv.Close()

	// Stalled: send the request, read nothing.
	conn, err := net.Dial("tcp", strings.TrimPrefix(srv.URL, "http://"))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	fmt.Fprintf(conn, "GET /x HTTP/1.1\r\nHost: x\r\n\r\n")
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("stalled reader: the whole blob was written")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("stalled reader still holds the response after 5 s")
	}

	// Control: a reader that keeps up gets the whole blob.
	resp, err := http.Get(srv.URL + "/y")
	if err != nil {
		t.Fatal(err)
	}
	n, _ := io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	if err := <-done; err != nil || n != size {
		t.Errorf("reading reader: got %d of %d bytes, server error %v", n, size, err)
	}
}
