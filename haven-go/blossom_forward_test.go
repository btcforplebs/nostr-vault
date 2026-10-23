package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
	"github.com/spf13/afero"
)

// forwardFixture: an in-memory blob store, one whitelisted owner, and a
// stand-in public Blossom server on loopback.
type forwardFixture struct {
	ownerSK string
	blob    []byte
	sha     string
	server  *httptest.Server
	got     atomic.Int32 // uploads the public server took
	answers []int        // status per upload attempt; last one repeats
	calls   atomic.Int32
	auth    atomic.Value // last Authorization seen
	listed  []string     // the owner's 10063 servers
}

func newForwardFixture(t *testing.T, answers ...int) *forwardFixture {
	t.Helper()
	f := &forwardFixture{ownerSK: nostr.GeneratePrivateKey(), blob: []byte("a photo from the 12 mini"), answers: answers}
	sum := sha256.Sum256(f.blob)
	f.sha = hex.EncodeToString(sum[:])
	owner, _ := nostr.GetPublicKey(f.ownerSK)

	oldFs, oldPath, oldWL := fs, config.BlossomPath, config.WhitelistedPubKeys
	oldClient, oldRefused, oldListed := forwardClient, forwardHostRefused, forwardTargetListed
	t.Cleanup(func() {
		fs, config.BlossomPath, config.WhitelistedPubKeys = oldFs, oldPath, oldWL
		forwardClient, forwardHostRefused, forwardTargetListed = oldClient, oldRefused, oldListed
	})
	fs = afero.NewMemMapFs()
	config.BlossomPath = "blossom/"
	config.WhitelistedPubKeys = map[string]struct{}{owner: {}}

	f.server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := int(f.calls.Add(1)) - 1
		f.auth.Store(r.Header.Get("Authorization"))
		body, _ := io.ReadAll(r.Body)
		code := http.StatusOK
		if len(f.answers) > 0 {
			code = f.answers[min(n, len(f.answers)-1)]
		}
		if r.Method == http.MethodPut && r.URL.Path == "/upload" && code == http.StatusOK {
			if s := sha256.Sum256(body); hex.EncodeToString(s[:]) == f.sha {
				f.got.Add(1)
			}
		}
		w.WriteHeader(code)
	}))
	t.Cleanup(f.server.Close)
	forwardClient = f.server.Client()
	forwardHostRefused = func(string) bool { return false }
	f.listed = []string{f.server.URL}
	forwardTargetListed = func(_ context.Context, pubkey, target string) bool {
		if pubkey != owner {
			return false
		}
		for _, s := range f.listed {
			if s == target {
				return true
			}
		}
		return false
	}
	return f
}

func (f *forwardFixture) token(t *testing.T, sk string, tags nostr.Tags) string {
	t.Helper()
	ev := nostr.Event{Kind: 24242, CreatedAt: nostr.Now(), Tags: tags, Content: "Upload"}
	if err := ev.Sign(sk); err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(ev)
	return "Nostr " + base64.RawURLEncoding.EncodeToString(raw) // BUD-11 form
}

func (f *forwardFixture) uploadTags(sha string, expires time.Time) nostr.Tags {
	return nostr.Tags{{"t", "upload"}, {"x", sha}, {"expiration", strconv.FormatInt(expires.Unix(), 10)}}
}

func (f *forwardFixture) request(target, auth string) *http.Request {
	return f.requestWithBody(target, auth, f.blob)
}

func (f *forwardFixture) requestWithBody(target, auth string, body []byte) *http.Request {
	r := httptest.NewRequest(http.MethodPut, "/upload", bytes.NewReader(body))
	r.Header.Set(forwardToHeader, target)
	r.Header.Set(forwardAuthHeader, auth)
	r.Header.Set("X-SHA-256", f.sha)
	return r
}

// reads the body, stores it under its own hash and answers like the relay's
// Blossom upload.
func (f *forwardFixture) relay(status int) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		if status == http.StatusOK {
			sum := sha256.Sum256(body)
			_ = afero.WriteFile(fs, config.BlossomPath+hex.EncodeToString(sum[:]), body, 0o644)
		}
		w.WriteHeader(status)
	})
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestForwardCarriesTheOwnersTokenToThePublicServer(t *testing.T) {
	f := newForwardFixture(t)
	auth := f.token(t, f.ownerSK, f.uploadTags(f.sha, time.Now().Add(time.Hour)))
	w := httptest.NewRecorder()
	serveWithForward(w, f.request(f.server.URL, auth), f.relay(http.StatusOK))
	if w.Code != http.StatusOK {
		t.Fatalf("upload answered %d", w.Code)
	}
	waitFor(t, "the public server to get the blob", func() bool { return f.got.Load() == 1 })
	// Normalised to padded standard base64, the same token the phone signed.
	raw, _ := decodeNostrAuthToken(auth[6:])
	if got := f.auth.Load(); got != "Nostr "+base64.StdEncoding.EncodeToString(raw) {
		t.Fatalf("public server saw Authorization %v", got)
	}
}

func TestNoForwardWhenTheUploadFails(t *testing.T) {
	f := newForwardFixture(t)
	// Already on the Mac from before: only the refusal may stop the forward.
	_ = afero.WriteFile(fs, config.BlossomPath+f.sha, f.blob, 0o644)
	auth := f.token(t, f.ownerSK, f.uploadTags(f.sha, time.Now().Add(time.Hour)))
	w := httptest.NewRecorder()
	serveWithForward(w, f.request(f.server.URL, auth), f.relay(http.StatusForbidden))
	time.Sleep(200 * time.Millisecond)
	if f.calls.Load() != 0 {
		t.Fatal("forwarded a blob the relay did not store")
	}
}

func TestUploadWithoutForwardHeadersIsUntouched(t *testing.T) {
	f := newForwardFixture(t)
	r := httptest.NewRequest(http.MethodPut, "/upload", nil)
	w := httptest.NewRecorder()
	serveWithForward(w, r, f.relay(http.StatusOK))
	time.Sleep(100 * time.Millisecond)
	if w.Code != http.StatusOK || f.calls.Load() != 0 {
		t.Fatalf("plain upload: code %d, forwards %d", w.Code, f.calls.Load())
	}
}

// Every way the Mac could be made to carry someone else's blob, or to a
// place it should not go, is refused before the upload runs.
func TestForwardRefusesBadRequests(t *testing.T) {
	f := newForwardFixture(t)
	stranger := nostr.GeneratePrivateKey()
	other := hex.EncodeToString(make([]byte, 32))
	good := f.uploadTags(f.sha, time.Now().Add(time.Hour))
	cases := map[string]*http.Request{
		"stranger's key": f.request(f.server.URL, f.token(t, stranger, good)),
		"expired":        f.request(f.server.URL, f.token(t, f.ownerSK, f.uploadTags(f.sha, time.Now().Add(-time.Minute)))),
		"other blob":     f.request(f.server.URL, f.token(t, f.ownerSK, f.uploadTags(other, time.Now().Add(time.Hour)))),
		"not an upload":  f.request(f.server.URL, f.token(t, f.ownerSK, nostr.Tags{{"t", "delete"}, {"x", f.sha}, {"expiration", good[2][1]}})),
		"plain http":     f.request("http://blossom.example.com", f.token(t, f.ownerSK, good)),
		"no token":       f.request(f.server.URL, ""),
		"garbage token":  f.request(f.server.URL, "Nostr !!!"),
		"no expiration":  f.request(f.server.URL, f.token(t, f.ownerSK, nostr.Tags{{"t", "upload"}, {"x", f.sha}})),
		"no X-SHA-256": func() *http.Request {
			r := f.request(f.server.URL, f.token(t, f.ownerSK, good))
			r.Header.Del("X-SHA-256")
			return r
		}(),
		"target not in 10063": f.request("https://blossom.elsewhere.example", f.token(t, f.ownerSK, good)),
		"not PUT /upload": func() *http.Request {
			r := f.request(f.server.URL, f.token(t, f.ownerSK, good))
			r.URL.Path = "/mirror"
			return r
		}(),
	}
	for name, r := range cases {
		w := httptest.NewRecorder()
		ran := false
		serveWithForward(w, r, http.HandlerFunc(func(http.ResponseWriter, *http.Request) { ran = true }))
		if w.Code != http.StatusBadRequest || ran {
			t.Errorf("%s: code %d, upload ran %v", name, w.Code, ran)
		}
	}
	if f.calls.Load() != 0 {
		t.Fatal("a refused request was forwarded")
	}
}

func TestForwardTargetsMustBePublic(t *testing.T) {
	for _, host := range []string{"localhost", "127.0.0.1", "192.168.4.20", "10.0.0.5", "100.105.71.2",
		"mac.tailnet.ts.net", "npub1abc.fips", "printer.local", "fe80::1", "::1", "intranet"} {
		if !forwardHostIsPrivate(host) {
			t.Errorf("%s accepted as a public forward target", host)
		}
	}
	for _, host := range []string{"logen.btcforplebs.com", "blossom.primal.net", "8.8.8.8"} {
		if forwardHostIsPrivate(host) {
			t.Errorf("%s refused", host)
		}
	}
	// A public name that resolves to a private address is refused at dial time.
	if forwardDialControl("tcp", "192.168.4.20:443", nil) == nil || forwardDialControl("tcp", "127.0.0.1:443", nil) == nil {
		t.Error("dial to a private address allowed")
	}
	if err := forwardDialControl("tcp", "8.8.8.8:443", nil); err != nil {
		t.Errorf("dial to a public address refused: %v", err)
	}
}

func TestForwardRetriesABusyServerAndStopsOnARefusal(t *testing.T) {
	f := newForwardFixture(t, http.StatusServiceUnavailable, http.StatusServiceUnavailable, http.StatusOK)
	_ = afero.WriteFile(fs, config.BlossomPath+f.sha, f.blob, 0o644)
	fwd := &blobForward{target: f.server.URL, sha256: f.sha, authB64: "x", expiresAt: time.Now().Add(24 * time.Hour)}
	noWait := func(context.Context, time.Duration) bool { return true }
	if err := runBlobForward(context.Background(), fwd, time.Now, noWait); err != nil || f.got.Load() != 1 || f.calls.Load() != 3 {
		t.Fatalf("busy server: err %v, stored %d, calls %d", err, f.got.Load(), f.calls.Load())
	}

	f2 := newForwardFixture(t, http.StatusForbidden)
	_ = afero.WriteFile(fs, config.BlossomPath+f2.sha, f2.blob, 0o644)
	fwd.target = f2.server.URL
	if err := runBlobForward(context.Background(), fwd, time.Now, noWait); err == nil || f2.calls.Load() != 1 {
		t.Fatalf("refusal: err %v, calls %d (want one try)", err, f2.calls.Load())
	}
}

func TestForwardStopsAtTheTokensExpiry(t *testing.T) {
	f := newForwardFixture(t, http.StatusServiceUnavailable)
	_ = afero.WriteFile(fs, config.BlossomPath+f.sha, f.blob, 0o644)
	// 20 s left: the first 30 s backoff would outlive the token.
	fwd := &blobForward{target: f.server.URL, sha256: f.sha, authB64: "x", expiresAt: time.Now().Add(20 * time.Second)}
	if err := runBlobForward(context.Background(), fwd, time.Now, func(context.Context, time.Duration) bool { return true }); err == nil || f.calls.Load() != 1 {
		t.Fatalf("err %v, calls %d", err, f.calls.Load())
	}
}

// Tron, PR 971: a token for blob A sent along with blob B must not carry A
// (already stored on the Mac) out. Headers and token all name A; only the
// bytes are B's.
func TestForwardIsBoundToTheUploadedBytes(t *testing.T) {
	f := newForwardFixture(t)
	_ = afero.WriteFile(fs, config.BlossomPath+f.sha, f.blob, 0o644) // A, stored earlier
	auth := f.token(t, f.ownerSK, f.uploadTags(f.sha, time.Now().Add(time.Hour)))
	w := httptest.NewRecorder()
	serveWithForward(w, f.requestWithBody(f.server.URL, auth, []byte("blob B, something else")), f.relay(http.StatusOK))
	time.Sleep(200 * time.Millisecond)
	if f.calls.Load() != 0 {
		t.Fatal("forwarded a stored blob the upload did not carry")
	}
}

func TestServerListNamesTheTarget(t *testing.T) {
	tags := nostr.Tags{{"server", "https://logen.btcforplebs.com/"}, {"server", "fipsmesh://npub1x/"}}
	if !serverListNames(tags, "https://logen.btcforplebs.com") || !serverListNames(tags, "https://LOGEN.btcforplebs.com") {
		t.Fatal("listed server not found")
	}
	if serverListNames(tags, "https://blossom.band") || serverListNames(nostr.Tags{{"r", "https://blossom.band"}}, "https://blossom.band") {
		t.Fatal("unlisted server accepted")
	}
}

// The real lookup: the signer's NEWEST 10063 on this relay decides.
func TestForwardTargetListedReadsTheNewestServerList(t *testing.T) {
	skipWithoutSockets(t)
	h := startHaven(t)
	owner, _ := nostr.GetPublicKey(h.ownerSK)
	now := time.Now().Unix()
	older := nostr.Event{Kind: 10063, CreatedAt: nostr.Timestamp(now - 100), Tags: nostr.Tags{{"server", "https://old.example.com"}}}
	newer := nostr.Event{Kind: 10063, CreatedAt: nostr.Timestamp(now - 10), Tags: nostr.Tags{{"server", "https://logen.btcforplebs.com/"}}}
	for _, ev := range []*nostr.Event{&older, &newer} {
		if err := ev.Sign(h.ownerSK); err != nil {
			t.Fatal(err)
		}
	}
	saveAll(t, outboxDB, &older, &newer)
	ctx := context.Background()
	if !forwardTargetListed(ctx, owner, "https://logen.btcforplebs.com") {
		t.Fatal("server in the newest list refused")
	}
	if forwardTargetListed(ctx, owner, "https://old.example.com") {
		t.Fatal("server only in an older list accepted")
	}
	if forwardTargetListed(ctx, strings.Repeat("b", 64), "https://logen.btcforplebs.com") {
		t.Fatal("another key's target accepted")
	}
}
