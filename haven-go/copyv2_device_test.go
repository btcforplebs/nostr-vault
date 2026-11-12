package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/nbd-wtf/go-nostr"
)

// Multi-Mac rules §3.3: a Mac's web domain goes to own devices over the
// mesh only, and only when it is a public name.
func TestCopyWebDomainOnlyPublicNames(t *testing.T) {
	for raw, want := range map[string]string{
		"vault.example.com":            "vault.example.com",
		"https://Vault.Example.com/x/": "vault.example.com",
		"wss://relay.example.org":      "relay.example.org",
		"vault.example.com.":           "vault.example.com",
		"":                             "",
		"localhost":                    "",
		"192.168.1.20":                 "",
		"100.64.0.1":                   "",
		"fd00::1":                      "",
		"[2001:db8::1]":                "",
		"vault.example.com:8443":       "",
		"mac.local":                    "",
		"npub1abc.fips":                "",
		"box.tail1234.ts.net":          "",
		"x.onion":                      "",
		"nas.home.arpa":                "",
		"router.lan":                   "",
		"bad_name.example.com":         "",
		"-x.example.com":               "",
		"example":                      "",
		"1.2.3.4.5":                    "",
	} {
		if got := copyWebDomain(raw); got != want {
			t.Errorf("copyWebDomain(%q) = %q, want %q", raw, got, want)
		}
	}
}

// domainProof: what the Mac app signs with its mesh key (MeshDomainProof).
func domainProof(t *testing.T, k testKey, domain string, at int64) *nostr.Event {
	t.Helper()
	ev := k.sign(t, nostr.Event{Kind: copyDomainProofKind, CreatedAt: nostr.Timestamp(at), Tags: nostr.Tags{{"domain", domain}}})
	return &ev
}

func proofJSON(t *testing.T, ev *nostr.Event) string {
	t.Helper()
	raw, err := json.Marshal(ev)
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

// copyDevicePair: A (this Mac, mesh key mac) serving one phone's token.
func copyDevicePair(t *testing.T) (mac, phone testKey, s *copyServer, url string) {
	t.Helper()
	owner := newTestKey(t)
	mac, phone = newTestKey(t), newTestKey(t)
	openCopyVault(t, owner.pk)
	pairMeshDevices(t, mac, phone)
	_, s = copySyncPair(t, owner)
	s.tokens[0].Device = phone.pk
	saveCopyPeerToken(npubOf(t, mac.pk), copyPeerToken("npub1peer"))
	ts := httptest.NewServer(s)
	t.Cleanup(ts.Close)
	prev := config.WebDomainProof
	t.Cleanup(func() { config.WebDomainProof = prev })
	return mac, phone, s, ts.URL
}

// A catch-up hands over the Mac's signed domain, kept under the Mac.
func TestCopyCatchUpTakesTheMacsSignedDomain(t *testing.T) {
	mac, _, _, url := copyDevicePair(t)
	config.WebDomainProof = proofJSON(t, domainProof(t, mac, "Vault.Example.com", 100))
	c := newCopyClient(npubOf(t, mac.pk), url)
	if _, err := c.sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := loadCopyPeerDomains()[npubOf(t, mac.pk)].Domain; got != "vault.example.com" {
		t.Fatalf("the Mac's domain was not kept: %v", loadCopyPeerDomains())
	}

	// No proof any more (the Mac went mesh only): forgotten next round.
	config.WebDomainProof = ""
	if _, err := c.sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := loadCopyPeerDomains(); len(got) != 0 {
		t.Fatalf("a mesh-only Mac still has a domain: %v", got)
	}
}

// The engine never hands out a proof that is not its own, signed, public.
func TestCopyOwnDomainProofChecks(t *testing.T) {
	mac, phone, _, _ := copyDevicePair(t)
	good := domainProof(t, mac, "vault.example.com", 100)
	tampered := *good
	tampered.Tags = nostr.Tags{{"domain", "evil.example.com"}}
	for name, raw := range map[string]string{
		"another key's": proofJSON(t, domainProof(t, phone, "vault.example.com", 100)),
		"an IP":         proofJSON(t, domainProof(t, mac, "203.0.113.7", 100)),
		"a home name":   proofJSON(t, domainProof(t, mac, "mac.local", 100)),
		"tampered":      proofJSON(t, &tampered),
		"another kind": proofJSON(t, func() *nostr.Event {
			e := mac.sign(t, nostr.Event{Kind: 1, Tags: nostr.Tags{{"domain", "vault.example.com"}}})
			return &e
		}()),
		"not JSON": "vault.example.com",
	} {
		config.WebDomainProof = raw
		if copyOwnDomainProof() != nil {
			t.Errorf("%s proof was handed out", name)
		}
	}
	config.WebDomainProof = proofJSON(t, good)
	if copyOwnDomainProof() == nil {
		t.Fatal("the Mac's own good proof was not handed out")
	}
}

// PUT keeps a proof only when the token's own device signed it.
func TestCopyDevicePutKeepsOnlyTheTokenDevicesProof(t *testing.T) {
	mac, phone, _, url := copyDevicePair(t)
	put := func(auth, body string) int {
		req, _ := http.NewRequest(http.MethodPut, url+"/copy/v2/sync/device", strings.NewReader(body))
		if auth != "" {
			req.Header.Set("Authorization", "Bearer "+auth)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	body := func(ev *nostr.Event) string { return `{"proof":` + proofJSON(t, ev) + `}` }
	token := copyPeerToken("npub1peer")

	if c := put("", body(domainProof(t, phone, "phone.example.com", 100))); c != http.StatusUnauthorized {
		t.Fatalf("no token: %d", c)
	}
	// The Mac's key, sent on the phone's token: not the phone's, not kept.
	if c := put(token, body(domainProof(t, mac, "evil.example.com", 100))); c != http.StatusOK {
		t.Fatalf("put: %d", c)
	}
	if got := loadCopyPeerDomains(); len(got) != 0 {
		t.Fatalf("another key's proof was kept: %v", got)
	}
	if c := put(token, body(domainProof(t, phone, "phone.example.com", 200))); c != http.StatusOK {
		t.Fatalf("put: %d", c)
	}
	// An older proof never undoes a newer one.
	put(token, body(domainProof(t, phone, "old.example.com", 150)))
	if got := loadCopyPeerDomains()[npubOf(t, phone.pk)]; got.Domain != "phone.example.com" || got.At != 200 {
		t.Fatalf("got %v", loadCopyPeerDomains())
	}
	var out map[string]string
	if err := json.Unmarshal([]byte(copyPeerDomainsJSON()), &out); err != nil {
		t.Fatal(err)
	}
	if len(out) != 1 || out[npubOf(t, phone.pk)] != "phone.example.com" {
		t.Fatalf("app sees %v", out)
	}
	// Unpaired: the app no longer sees it.
	pairMeshDevices(t, mac)
	if got := copyPeerDomainsJSON(); got != "{}" {
		t.Fatalf("an unpaired device's domain is still shown: %s", got)
	}
}

// A light device's catch-up never asks for files, and keeps its own mark.
func TestCopyNotesOnlyCatchUpSkipsFiles(t *testing.T) {
	owner := newTestKey(t)
	openCopyVault(t, owner.pk)
	_, s := copySyncPair(t, owner)
	var fileCalls atomic.Int32
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/copy/v2/sync/file") {
			fileCalls.Add(1)
		}
		s.ServeHTTP(w, r)
	}))
	defer ts.Close()

	c := newCopyClient("npub1peer", ts.URL)
	c.notesOnly = true
	if _, err := c.sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	if n := fileCalls.Load(); n != 0 {
		t.Fatalf("a light catch-up asked for files %d times", n)
	}
	marks := loadCopySync()
	if marks[copyPeerKey("npub1peer")] != 0 || marks[copyPeerKey("npub1peer"+copySyncNotesOnlyMark)] == 0 {
		t.Fatalf("marks: %v (a notes-only round must not move the full mark)", marks)
	}

	if _, err := newCopyClient("npub1peer", ts.URL).sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	if fileCalls.Load() == 0 {
		t.Fatal("a full catch-up did not ask for files")
	}
	if loadCopySync()[copyPeerKey("npub1peer")] == 0 {
		t.Fatal("a full round was not marked")
	}
	clearCopySynced("npub1peer")
	if m := loadCopySync(); len(m) != 0 {
		t.Fatalf("forgetting the peer kept a mark: %v", m)
	}
}
