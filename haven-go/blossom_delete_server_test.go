package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	"github.com/fiatjaf/khatru"
	"github.com/fiatjaf/khatru/blossom"
	"github.com/nbd-wtf/go-nostr"
)

// A vault whose public domain is vault.example, holding one blob of the
// owner's. Returns the server URL, the owner's key and the blob's hash; each
// call to deleted reports whether the blob is gone.
func deleteServerVault(t *testing.T) (base, sk, hash string, deleted func() bool) {
	t.Helper()
	savedURL := config.RelayURL
	t.Cleanup(func() { config.RelayURL = savedURL })
	config.RelayURL = "vault.example"

	sk = nostr.GeneratePrivateKey()
	pk, _ := nostr.GetPublicKey(sk)
	hash = blobHash('d')

	index := newTestBackend(t, "blossom")
	if err := index.Init(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(index.Close)
	relay := khatru.NewRelay()
	bs := blossom.New(relay, "https://vault.example")
	store := blossom.EventStoreBlobIndexWrapper{Store: index, ServiceURL: bs.ServiceURL}
	bs.Store = store
	guardDeleteServer(bs)
	if err := store.Keep(context.Background(), blossom.BlobDescriptor{SHA256: hash, Size: 1, Type: "image/jpeg", Uploaded: nostr.Now()}, pk); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(relay)
	t.Cleanup(srv.Close)
	return srv.URL, sk, hash, func() bool {
		bd, err := store.Get(context.Background(), hash)
		return err == nil && bd == nil
	}
}

func deleteToken(t *testing.T, sk, hash string, expires time.Time, servers ...string) string {
	t.Helper()
	tags := nostr.Tags{{"t", "delete"}, {"x", hash}, {"expiration", strconv.FormatInt(expires.Unix(), 10)}}
	for _, s := range servers {
		tags = append(tags, nostr.Tag{"server", s})
	}
	ev := nostr.Event{Kind: 24242, CreatedAt: nostr.Now(), Content: "Delete blob", Tags: tags}
	if err := ev.Sign(sk); err != nil {
		t.Fatal(err)
	}
	j, _ := json.Marshal(ev)
	return "Nostr " + base64.StdEncoding.EncodeToString(j)
}

func sendDelete(t *testing.T, base, hash, auth string) int {
	t.Helper()
	req, _ := http.NewRequest(http.MethodDelete, base+"/"+hash, nil)
	if auth != "" {
		req.Header.Set("Authorization", auth)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	return resp.StatusCode
}

// The hole: a token made for a public mirror, replayed against the vault.
func TestDeleteRefusesTokenForAnotherServer(t *testing.T) {
	base, sk, hash, deleted := deleteServerVault(t)
	auth := deleteToken(t, sk, hash, time.Now().Add(5*time.Minute), "blossom.primal.net")
	if got := sendDelete(t, base, hash, auth); got != 403 {
		t.Fatalf("token for blossom.primal.net: %d, want 403", got)
	}
	if deleted() {
		t.Fatal("blob deleted with another server's token")
	}
}

func TestDeleteAcceptsTokenNamingThisVault(t *testing.T) {
	for _, server := range []string{"vault.example", "https://VAULT.example/", "localhost", "npub1abc.fips"} {
		t.Run(server, func(t *testing.T) {
			base, sk, hash, deleted := deleteServerVault(t)
			// A token may name several servers; one of them being this vault is enough.
			auth := deleteToken(t, sk, hash, time.Now().Add(5*time.Minute), "blossom.primal.net", server)
			if got := sendDelete(t, base, hash, auth); got != 200 {
				t.Fatalf("token naming %s: %d, want 200", server, got)
			}
			if !deleted() {
				t.Fatal("blob still there")
			}
		})
	}
}

// Decision: no "server" tag is still accepted (Android and other apps do not
// send one yet), unless deleteNeedsServerTag is switched on.
func TestDeleteWithoutServerTag(t *testing.T) {
	base, sk, hash, deleted := deleteServerVault(t)
	saved := deleteNeedsServerTag
	t.Cleanup(func() { deleteNeedsServerTag = saved })

	deleteNeedsServerTag = true
	if got := sendDelete(t, base, hash, deleteToken(t, sk, hash, time.Now().Add(5*time.Minute))); got != 403 {
		t.Fatalf("no server tag, tag required: %d, want 403", got)
	}
	if deleted() {
		t.Fatal("deleted without a server tag while one is required")
	}

	deleteNeedsServerTag = false
	if got := sendDelete(t, base, hash, deleteToken(t, sk, hash, time.Now().Add(5*time.Minute))); got != 200 {
		t.Fatalf("no server tag, today's default: %d, want 200", got)
	}
}

func TestDeleteRefusesExpiredToken(t *testing.T) {
	base, sk, hash, deleted := deleteServerVault(t)
	auth := deleteToken(t, sk, hash, time.Now().Add(-time.Second), "vault.example")
	if got := sendDelete(t, base, hash, auth); got == 200 {
		t.Fatalf("expired token: %d, want a refusal", got)
	}
	if deleted() {
		t.Fatal("blob deleted with an expired token")
	}
}

func TestDeleteWithoutAuthorizationIsRefused(t *testing.T) {
	base, _, hash, deleted := deleteServerVault(t)
	if got := sendDelete(t, base, hash, ""); got != 401 {
		t.Fatalf("no Authorization: %d, want 401", got)
	}
	if deleted() {
		t.Fatal("blob deleted with no Authorization")
	}
}

func TestServerTagHost(t *testing.T) {
	for in, want := range map[string]string{
		"blossom.example":          "blossom.example",
		"Blossom.Example.":         "blossom.example",
		"https://blossom.example/": "blossom.example",
		"blossom.example:443":      "blossom.example",
		"http://[::1]:3355":        "::1",
		"":                         "",
	} {
		if got := serverTagHost(in); got != want {
			t.Errorf("serverTagHost(%q) = %q, want %q", in, got, want)
		}
	}
}
