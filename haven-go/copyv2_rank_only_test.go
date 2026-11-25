//go:build !(js && wasm)

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/barrydeen/haven/pkg/trustrank"
	"github.com/nbd-wtf/go-nostr"
)

// All keys are throwaway; the mesh never uses the account key.

// rankPair: A is a Mac (self) with a result for owner, the phone is paired
// with it and holds nothing from it: no first copy, no token.
func rankPair(t *testing.T) (owner, mac, phone testKey, s *copyServer, url, bDir string) {
	t.Helper()
	owner, mac, phone = newTestKey(t), newTestKey(t), newTestKey(t)
	openCopyVault(t, owner.pk)
	pairMeshDevices(t, mac, phone)
	s = newTestCopyServer(failingBuild)
	s.loaded = true
	ts := httptest.NewServer(s)
	t.Cleanup(ts.Close)
	aDir := t.TempDir()
	bDir = t.TempDir()
	config.WotCachePath = filepath.Join(aDir, "wot_cache.json")
	prevDir, prevTakes := copyTrustKeepDir, trustRankTakesCopy
	copyTrustKeepDir = func() string { return bDir }
	trustRankTakesCopy = func() bool { return true }
	t.Cleanup(func() { copyTrustKeepDir, trustRankTakesCopy = prevDir, prevTakes })
	writeTrustFile(t, aDir, owner.pk, 100)
	return owner, mac, phone, s, ts.URL, bDir
}

func rankStartAs(s *copyServer, auth string) (int, string) {
	req := copyReq(http.MethodPost, copyRankStartPath, nil)
	if auth != "" {
		req.Header.Set("Authorization", "Nostr "+auth)
	}
	rec := httptest.NewRecorder()
	s.ServeHTTP(rec, req)
	var out struct{ Token string }
	_ = json.Unmarshal(rec.Body.Bytes(), &out)
	return rec.Code, out.Token
}

// The rank-only start: a paired device's mesh key only, never the account
// key, a token that reads the trust rank and nothing else, and no copy job.
func TestRankStartGivesATrustOnlyToken(t *testing.T) {
	owner, mac, phone, s, _, _ := rankPair(t)
	stranger := newTestKey(t)
	me := meshNpub(mac.pk)
	at := nostr.Now()
	cases := []struct {
		name string
		auth string
		want int
	}{
		{"no proof", "", 401},
		{"stale", nudgeProof(t, phone, me, at-120, copyRankStartPath), 401},
		{"a full start's proof", nudgeProof(t, phone, me, at-1, "/copy/v2/start"), 401},
		{"for another vault", nudgeProof(t, phone, meshNpub(stranger.pk), at-2, copyRankStartPath), 401},
		{"a stranger", nudgeProof(t, stranger, me, at-3, copyRankStartPath), 403},
		{"the owner's account key", nudgeProof(t, owner, me, at-4, copyRankStartPath), 403},
	}
	for _, c := range cases {
		if got, _ := rankStartAs(s, c.auth); got != c.want {
			t.Errorf("%s: %d, want %d", c.name, got, c.want)
		}
	}
	// A rank proof is no full start either: its u names the rank path.
	if code, _, _ := startAs(t, s, nudgeProof(t, phone, me, at-5, copyRankStartPath)); code != 401 {
		t.Errorf("a rank proof at /copy/v2/start: %d, want 401", code)
	}
	good := nudgeProof(t, phone, me, at, copyRankStartPath)
	code, token := rankStartAs(s, good)
	if code != 200 || !copyIsHex(token, 64) {
		t.Fatalf("the phone's rank start: %d %q", code, token)
	}
	if again, _ := rankStartAs(s, good); again != 401 {
		t.Errorf("the same proof again: %d, want 401", again)
	}
	if len(s.jobs) != 0 {
		t.Fatalf("a rank start built a copy: %d jobs", len(s.jobs))
	}
	if got := getWith(s, "/copy/v2/sync/trust?account="+owner.pk, token, "", nil); got != 200 {
		t.Fatalf("the rank token reads the rank: %d", got)
	}
	for _, path := range []string{"/copy/v2/sync/ids?store=outbox", "/copy/v2/sync/accounts", "/copy/v2/" + strings.Repeat("ab", 16), "/copy/v2/" + strings.Repeat("ab", 16) + "/notes"} {
		if got := getWith(s, path, token, "", nil); got != 401 {
			t.Errorf("the rank token reads %s: %d, want 401", path, got)
		}
	}
	// Remove device: the rank token goes with the rest.
	if !s.revoke(phone.pk) {
		t.Fatal("revoke held nothing")
	}
	if got := getWith(s, "/copy/v2/sync/trust?account="+owner.pk, token, "", nil); got != 401 {
		t.Fatalf("a removed device's rank token: %d, want 401", got)
	}
}

// A rank start never takes a device's copy token away (a copy or catch-up
// may be using it), and a second rank start replaces only the first.
func TestRankStartKeepsTheCopyToken(t *testing.T) {
	_, mac, phone, s, _, _ := rankPair(t)
	full := copyRandomHex(32)
	s.tokens = []copyToken{{Hash: copyHashToken(full), Owner: config.OwnerPubKey, Device: phone.pk, Created: time.Now().Unix(), LastUsed: time.Now().Unix()}}
	me := meshNpub(mac.pk)
	_, first := rankStartAs(s, nudgeProof(t, phone, me, nostr.Now(), copyRankStartPath))
	_, second := rankStartAs(s, nudgeProof(t, phone, me, nostr.Now()-1, copyRankStartPath))
	if first == "" || second == "" {
		t.Fatal("rank starts refused")
	}
	if got := getWith(s, "/copy/v2/sync/ids?store=outbox", full, "", nil); got == 401 {
		t.Fatal("a rank start dropped the copy token")
	}
	if got := getWith(s, "/copy/v2/sync/trust?account="+config.OwnerPubKey, first, "", nil); got != 401 {
		t.Errorf("the replaced rank token: %d, want 401", got)
	}
	if got := getWith(s, "/copy/v2/sync/trust?account="+config.OwnerPubKey, second, "", nil); got != 200 {
		t.Errorf("the new rank token: %d, want 200", got)
	}
}

// The phone's side: a pull with no first copy brings the rank over, keeps
// the token for the next pull (no new proof), and never makes the Mac a
// device this one "copied from".
func TestRankPullWithNoFirstCopy(t *testing.T) {
	owner, mac, phone, s, url, bDir := rankPair(t)
	peer := meshNpub(mac.pk)
	c := newCopyClient(peer, url)
	if _, err := c.rankPull(context.Background(), ""); copyErrorCode(err) != "auth_refused" {
		t.Fatalf("no token and no proof: %v, want auth_refused", err)
	}
	got, err := c.rankPull(context.Background(), nudgeProof(t, phone, peer, nostr.Now(), copyRankStartPath))
	if err != nil || got != 1 {
		t.Fatalf("first pull: got %d, err %v", got, err)
	}
	if f, err := trustrank.ReadResult(bDir, owner.pk); err != nil || f.BuiltAt != 100 {
		t.Fatalf("the phone has no rank: %v", err)
	}
	if _, held := copyRankHolds(mac.pk); !held {
		t.Fatal("the rank token was not kept")
	}
	if held := copyHeldPeers(); slices.Contains(held, peer) {
		t.Fatalf("a rank pull made the Mac a copied-from device: %v", held)
	}
	// Next pull: the held token, no proof, nothing new.
	if got, err := newCopyClient(peer, url).rankPull(context.Background(), ""); err != nil || got != 0 {
		t.Fatalf("second pull: got %d, err %v", got, err)
	}
	// Removed on the Mac: refused, and a fresh proof gets a new token.
	s.revoke(phone.pk)
	if _, err := newCopyClient(peer, url).rankPull(context.Background(), ""); copyErrorCode(err) != "auth_refused" {
		t.Fatalf("after remove: %v, want auth_refused", err)
	}
	if _, err := newCopyClient(peer, url).rankPull(context.Background(), nudgeProof(t, phone, peer, nostr.Now()-1, copyRankStartPath)); err != nil {
		t.Fatalf("a fresh proof after remove: %v", err)
	}
}

// A device that ranks for itself (a Mac, a box) asks nothing.
func TestRankPullNotOnADeviceThatRanks(t *testing.T) {
	_, mac, phone, s, url, _ := rankPair(t)
	trustRankTakesCopy = func() bool { return false }
	peer := meshNpub(mac.pk)
	if got, err := newCopyClient(peer, url).rankPull(context.Background(), nudgeProof(t, phone, peer, nostr.Now(), copyRankStartPath)); err != nil || got != 0 {
		t.Fatalf("got %d, err %v", got, err)
	}
	if len(s.tokens) != 0 {
		t.Fatal("a ranking device asked for a token")
	}
}

// The run's end line names the peer and how it went, and the Mac's nudge
// reaches a phone that holds only a rank token.
func TestRankPullLineAndNudge(t *testing.T) {
	_, mac, phone, _, url, _ := rankPair(t)
	var logs bytes.Buffer
	captureLog(t, &logs)
	peer := meshNpub(mac.pk)
	run := func(fn func()) { fn() }
	spawn := func(_ string, fn func()) { run(fn) }
	if rc := startRankPull(context.Background(), spawn, peer, url, nudgeProof(t, phone, peer, nostr.Now(), copyRankStartPath)); rc != 0 {
		t.Fatalf("rc %d", rc)
	}
	if line := lastLineWith(logs.String(), copyRankPulledMarker); !strings.Contains(line, copyRankPulledMarker+" peer="+peer+" got=1") || strings.Contains(line, "error=") {
		t.Fatalf("end line %q", line)
	}
	if rc := startRankPull(context.Background(), spawn, "npub1nobody", "http://127.0.0.1:1", ""); rc != 0 {
		t.Fatalf("rc %d", rc)
	}
	if line := lastLineWith(logs.String(), copyRankPulledMarker); !strings.HasSuffix(line, copyRankPulledMarker+" peer=npub1nobody got=0 error=auth_refused") {
		t.Fatalf("failed end line %q", line)
	}

	// On the phone (self), the Mac's nudge: 204 with a rank token only.
	pairMeshDevices(t, phone, mac)
	copyNudgeMu.Lock()
	copyNudgeLast = map[string]time.Time{}
	copyNudgeMu.Unlock()
	if got := nudgeAs(newTestCopyServer(nil), nudgeProof(t, mac, meshNpub(phone.pk), nostr.Now(), "/copy/v2/nudge")); got != 204 {
		t.Fatalf("the Mac's nudge to a rank-only phone: %d, want 204", got)
	}
	if !strings.Contains(logs.String(), copyNudgeMarker+" peer="+peer) {
		t.Fatalf("no %s line:\n%s", copyNudgeMarker, logs.String())
	}
}
