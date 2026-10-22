package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// HEAD over the mesh door follows GET's mesh rules (Tron, #1048). khatru
// answers HEAD from its blob index alone, so this test uploads for real:
// with no index entry every HEAD is 404 anyway, and a check proves nothing.
func TestMeshHeadIsNoOracle(t *testing.T) {
	h := startHaven(t)
	saved := meshBlobs
	meshBlobs = &meshBlobIndex{}
	t.Cleanup(func() { meshBlobs = saved })
	door := startMeshDoor(t)
	own := httptest.NewServer(http.HandlerFunc(dynamicRelayHandler))
	t.Cleanup(own.Close)

	body := []byte("a photo no note names yet")
	sum := sha256.Sum256(body)
	hash := hex.EncodeToString(sum[:])
	if code := meshPut(t, door, blossomUploadAuth(t, h.ownerSK, body), body); code != http.StatusOK {
		t.Fatalf("owner upload: %d", code)
	}

	getAuth := func(sk, x string, exp time.Duration) string {
		ev := nostr.Event{Kind: 24242, CreatedAt: nostr.Now(), Content: nostr.GeneratePrivateKey(),
			Tags: nostr.Tags{{"t", "get"}, {"x", x}, {"expiration", fmt.Sprint(time.Now().Add(exp).Unix())}}}
		if err := ev.Sign(sk); err != nil {
			t.Fatal(err)
		}
		j, _ := json.Marshal(ev)
		return "Nostr " + base64.StdEncoding.EncodeToString(j)
	}
	head := func(base, auth string) (int, string) {
		req, _ := http.NewRequest(http.MethodHead, base+"/"+hash, nil)
		if auth != "" {
			req.Header.Set("Authorization", auth)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode, resp.Header.Get("Content-Length")
	}

	if code, n := head(door, ""); code != http.StatusNotFound || n == fmt.Sprint(len(body)) {
		t.Errorf("stranger HEAD of an unposted blob: %d, length %q; want 404 and no size", code, n)
	}
	for name, auth := range map[string]string{
		"a stranger's get":                 getAuth(nostr.GeneratePrivateKey(), hash, time.Hour),
		"the owner's get, expired":         getAuth(h.ownerSK, hash, -time.Minute),
		"the owner's get for another blob": getAuth(h.ownerSK, hex.EncodeToString(make([]byte, 32)), time.Hour),
	} {
		if code, _ := head(door, auth); code != http.StatusNotFound {
			t.Errorf("HEAD with %s: %d, want 404", name, code)
		}
	}
	if code, n := head(door, getAuth(h.ownerSK, hash, time.Hour)); code != http.StatusOK || n != fmt.Sprint(len(body)) {
		t.Errorf("owner-signed HEAD over the mesh: %d, length %q; want 200", code, n)
	}
	// The owner's own app, and own devices on the relay port, are not the door.
	if code, _ := head(own.URL, ""); code != http.StatusOK {
		t.Errorf("unsigned HEAD on the relay port after an upload: %d, want 200 (the phone would send it again)", code)
	}

	// Once a public note names it, anyone may check it, as anyone may read it.
	note := nostr.Event{Kind: 1, CreatedAt: nostr.Now(), Content: "https://blossom.example/" + hash + ".jpg"}
	if err := note.Sign(h.ownerSK); err != nil {
		t.Fatal(err)
	}
	if err := outboxDB.SaveEvent(context.Background(), &note); err != nil {
		t.Fatal(err)
	}
	meshBlobs = &meshBlobIndex{}
	if code, _ := head(door, ""); code != http.StatusOK {
		t.Errorf("stranger HEAD of a posted blob: %d, want 200", code)
	}
}
