//go:build !(js && wasm)

package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip19"
)

// testDevice: the mesh pubkey B names in its start proof (throwaway).
var testDevice = strings.Repeat("b1", 32)

// copyReq: a request as the mesh hands it to this port, from loopback.
func copyReq(method, target string, body io.Reader) *http.Request {
	r := httptest.NewRequest(method, target, body)
	r.RemoteAddr = "127.0.0.1:50123"
	return r
}

// startProofFor: the owner's start proof naming device ("" names none).
func startProofFor(t *testing.T, k testKey, device string) string {
	t.Helper()
	tags := nostr.Tags{{"u", "http://127.0.0.1:9/copy/v2/start"}, {"method", "POST"}}
	if device != "" {
		tags = append(tags, nostr.Tag{"device", device})
	}
	ev := k.sign(t, nostr.Event{Kind: 27235, CreatedAt: nostr.Now(), Tags: tags})
	raw, _ := json.Marshal(ev)
	return base64.StdEncoding.EncodeToString(raw)
}

// startAs runs POST /copy/v2/start with auth and returns code, id, token.
func startAs(t *testing.T, s *copyServer, auth string) (int, string, string) {
	t.Helper()
	req := copyReq(http.MethodPost, "/copy/v2/start", nil)
	req.Header.Set("Authorization", "Nostr "+auth)
	rec := httptest.NewRecorder()
	s.ServeHTTP(rec, req)
	var out struct{ ID, Token string }
	_ = json.Unmarshal(rec.Body.Bytes(), &out)
	return rec.Code, out.ID, out.Token
}

func getWith(s *copyServer, path, token, remote string, hdr map[string]string) int {
	req := copyReq(http.MethodGet, path, nil)
	if remote != "" {
		req.RemoteAddr = remote
	}
	req.Header.Set("Authorization", "Bearer "+token)
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	s.ServeHTTP(rec, req)
	return rec.Code
}

func failingBuild(dir, id string, p copyBuildProgress) (copyManifest, error) {
	return copyManifest{}, fmt.Errorf("not in this test")
}

// Tron must-fix: Mac, Android and the box listen on the LAN, so a removed
// device there kept a working bearer. Only loopback reaches /copy/v2.
func TestCopyRefusesTheLAN(t *testing.T) {
	owner := newTestKey(t)
	openCopyVault(t, owner.pk)
	s := newTestCopyServer(failingBuild)
	code, id, token := startAs(t, s, startProofFor(t, owner, testDevice))
	if code != 200 {
		t.Fatalf("start: %d", code)
	}
	path := "/copy/v2/" + id
	cases := []struct {
		name   string
		remote string
		hdr    map[string]string
		want   int
	}{
		{"over the mesh (loopback)", "", nil, 200},
		{"over the mesh (::1)", "[::1]:4000", nil, 200},
		{"from the LAN", "192.168.1.20:5555", nil, 404},
		{"from the LAN, v4-mapped", "[::ffff:192.168.1.20]:5555", nil, 404},
		{"through the box's havend from the LAN", "", map[string]string{"X-Forwarded-For": "192.168.1.20"}, 404},
		{"through havend, LAN hop last", "", map[string]string{"X-Forwarded-For": "127.0.0.1, 192.168.1.20"}, 404},
		{"through havend from the mesh", "", map[string]string{"X-Forwarded-For": "127.0.0.1"}, 200},
		{"a Forwarded header", "", map[string]string{"Forwarded": "for=192.168.1.20"}, 404},
	}
	for _, c := range cases {
		if got := getWith(s, path, token, c.remote, c.hdr); got != c.want {
			t.Errorf("%s: %d, want %d", c.name, got, c.want)
		}
	}
	// The start itself is refused from the LAN too.
	req := httptest.NewRequest(http.MethodPost, "/copy/v2/start", nil)
	req.RemoteAddr = "10.0.0.7:1234"
	req.Header.Set("Authorization", "Nostr "+startProofFor(t, owner, testDevice))
	rec := httptest.NewRecorder()
	s.ServeHTTP(rec, req)
	if rec.Code != 404 {
		t.Errorf("start from the LAN: %d, want 404", rec.Code)
	}
}

// Tron must-fix (b)+(c): tokens are bound to B's mesh pubkey; a new start
// replaces that device's token, Remove device revokes it, and a start that
// names no device is refused.
func TestCopyTokenPerDeviceAndRevoke(t *testing.T) {
	owner := newTestKey(t)
	openCopyVault(t, owner.pk)
	s := newTestCopyServer(failingBuild)
	if code, _, _ := startAs(t, s, startProofFor(t, owner, "")); code != 401 {
		t.Errorf("no device: %d, want 401", code)
	}
	if code, _, _ := startAs(t, s, startProofFor(t, owner, "not-a-key")); code != 401 {
		t.Errorf("bad device: %d, want 401", code)
	}
	other := strings.Repeat("c2", 32)
	_, id1, tok1 := startAs(t, s, startProofFor(t, owner, testDevice))
	npub, _ := nip19.EncodePublicKey(testDevice)
	_, id2, tok2 := startAs(t, s, startProofFor(t, owner, npub)) // same device, by npub
	_, id3, tok3 := startAs(t, s, startProofFor(t, owner, other))
	if c := getWith(s, "/copy/v2/"+id1, tok1, "", nil); c != 401 {
		t.Errorf("replaced token: %d, want 401", c)
	}
	if c := getWith(s, "/copy/v2/"+id2, tok2, "", nil); c != 200 {
		t.Errorf("new token: %d, want 200", c)
	}
	if !s.revoke(npub) {
		t.Fatal("revoke: nothing held")
	}
	if s.revoke(testDevice) {
		t.Error("second revoke still found a token")
	}
	if c := getWith(s, "/copy/v2/"+id2, tok2, "", nil); c != 401 {
		t.Errorf("revoked token: %d, want 401", c)
	}
	if c := getWith(s, "/copy/v2/sync/ids", tok2, "", nil); c != 401 {
		t.Errorf("revoked token, catch-up: %d, want 401", c)
	}
	if c := getWith(s, "/copy/v2/"+id3, tok3, "", nil); c != 200 {
		t.Errorf("another device's token after revoke: %d, want 200", c)
	}
	// The revoke is on disk: a restarted A still refuses it.
	s2 := newTestCopyServer(failingBuild)
	if c := getWith(s2, "/copy/v2/sync/ids", tok2, "", nil); c != 401 {
		t.Errorf("revoked token after restart: %d, want 401", c)
	}
	if s.revoke("") {
		t.Error("revoke of no device revoked something")
	}
}

// Tron should-fix: bearer() touched s.tokens without the lock (go test -race).
func TestCopyBearerAndStartDoNotRace(t *testing.T) {
	owner := newTestKey(t)
	openCopyVault(t, owner.pk)
	s := newTestCopyServer(failingBuild)
	_, id, token := startAs(t, s, startProofFor(t, owner, strings.Repeat("d3", 32)))
	proofs := make([]string, 8)
	for i := range proofs {
		proofs[i] = startProofFor(t, owner, fmt.Sprintf("%064x", i+1))
	}
	// Make every bearer call write (LastUsed older than an hour).
	s.mu.Lock()
	for i := range s.tokens {
		s.tokens[i].LastUsed -= 7200
	}
	s.mu.Unlock()
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(2)
		go func(p string) { defer wg.Done(); startAs(t, s, p) }(proofs[i])
		go func() { defer wg.Done(); getWith(s, "/copy/v2/"+id, token, "", nil) }()
	}
	wg.Wait()
}

// Tron should-fix: B used A's answer as a file name. Only 32 lowercase hex
// ids are taken, and a manifest must be the one asked for.
func TestCopyClientTakesOnlyItsOwnID(t *testing.T) {
	openCopyVault(t, newTestKey(t).pk)
	answer := ""
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, answer)
	}))
	defer ts.Close()
	tok := strings.Repeat("a", 64)
	for _, id := range []string{"../../../../tmp/" + strings.Repeat("x", 16), strings.Repeat("A", 32), strings.Repeat("a", 31) + "/"} {
		answer = fmt.Sprintf(`{"id":%q,"token":%q,"state":"building"}`, id, tok)
		if _, err := newCopyClient(testDevice, ts.URL).start(context.Background(), "x"); copyErrorCode(err) != "bad_manifest" {
			t.Errorf("start answer id %q: %v, want bad_manifest", id, err)
		}
	}
	want := strings.Repeat("e", 32)
	answer = fmt.Sprintf(`{"v":2,"id":%q,"state":"ready"}`, strings.Repeat("f", 32))
	if _, err := newCopyClient(testDevice, ts.URL).manifest(context.Background(), want); copyErrorCode(err) != "bad_manifest" {
		t.Errorf("manifest for another id: %v, want bad_manifest", err)
	}
}

// Tron should-fix: a stopped copy logged net/http's error, which carries the
// whole URL and so the ingress token in its path.
func TestCopyStopLogHasNoIngressToken(t *testing.T) {
	openCopyVault(t, newTestKey(t).pk)
	var buf bytes.Buffer
	prev := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&buf, nil)))
	t.Cleanup(func() { slog.SetDefault(prev) })
	const secret = "INGRESSSECRET0123456789"
	base := "http://127.0.0.1:1/" + secret
	saveCopyPeerToken(testDevice, strings.Repeat("a", 64))
	if err := os.MkdirAll(filepath.Join(copyInDir, copyPeerKey(testDevice)), 0o700); err != nil {
		t.Fatal(err)
	}
	run := func(string, func()) {}
	run = func(_ string, fn func()) { fn() }
	startCopySync(context.Background(), run, testDevice, base, false)
	startCopyFrom(context.Background(), run, testDevice, base, "x")
	if !strings.Contains(buf.String(), "stopped") {
		t.Fatalf("no stop line logged: %q", buf.String())
	}
	if strings.Contains(buf.String(), secret) {
		t.Errorf("the log carries the ingress token: %q", buf.String())
	}
}
