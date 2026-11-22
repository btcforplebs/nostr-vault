//go:build !(js && wasm)

package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/barrydeen/haven/pkg/trustrank"
)

func trustHex(i int) string {
	return strings.Repeat("0", 60) + string("0123456789abcdef"[i/4096%16]) + string("0123456789abcdef"[i/256%16]) + string("0123456789abcdef"[i/16%16]) + string("0123456789abcdef"[i%16])
}

// trustPair: A (a Haven with a result file for owner) and a paired phone
// B that keeps its copy in its own folder. Returns A's folder, B's, the URL.
func trustPair(t *testing.T, builtAt int64) (owner testKey, aDir, bDir string, s *copyServer, url string) {
	t.Helper()
	owner = newTestKey(t)
	mac, phone := newTestKey(t), newTestKey(t)
	openCopyVault(t, owner.pk)
	pairMeshDevices(t, mac, phone)
	_, s = copySyncPair(t, owner)
	s.tokens[0].Device = phone.pk
	ts := httptest.NewServer(s)
	t.Cleanup(ts.Close)
	aDir, bDir = t.TempDir(), t.TempDir()
	config.WotCachePath = filepath.Join(aDir, "wot_cache.json")
	prevDir, prevTakes := copyTrustKeepDir, trustRankTakesCopy
	copyTrustKeepDir = func() string { return bDir }
	trustRankTakesCopy = func() bool { return true }
	t.Cleanup(func() { copyTrustKeepDir, trustRankTakesCopy = prevDir, prevTakes })
	if builtAt > 0 {
		writeTrustFile(t, aDir, owner.pk, builtAt)
	}
	return owner, aDir, bDir, s, ts.URL
}

// writeTrustFile: a whole result as the crawler writes it: a follow who
// shows 12 (ring 1 always travels), and ring-2 people at 80, 45, 44.9, 0.5.
func writeTrustFile(t *testing.T, dir, account string, builtAt int64) {
	t.Helper()
	f := trustrank.ResultFile{Account: account, BuiltAt: builtAt, Version: 2, MaxHop: 4, ViewBar: trustrank.DefaultViewBar,
		Params: trustrank.DefaultParams(),
		People: [][3]any{{trustHex(1), 12.0, 1}, {trustHex(2), 80.0, 2}, {trustHex(3), 45.0, 2}, {trustHex(4), 44.9, 2}, {trustHex(5), 0.5, 3}}}
	raw, err := json.Marshal(f)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(trustrank.ResultPath(dir, account), raw, 0o600); err != nil {
		t.Fatal(err)
	}
}

func trustGet(t *testing.T, url, query, bearer string) *http.Response {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, url+"/copy/v2/sync/trust"+query, nil)
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { resp.Body.Close() })
	return resp
}

// A catch-up leaves the phone with the Haven's result, rows over the floor
// only, and a second catch-up with nothing new moves nothing.
func TestCopyCatchUpHandsOverTheTrustRank(t *testing.T) {
	owner, aDir, bDir, _, url := trustPair(t, 100)
	c := newCopyClient("npub1peer", url)
	if _, err := c.sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	got, err := trustrank.ReadResult(bDir, owner.pk)
	if err != nil {
		t.Fatalf("the phone has no copy: %v", err)
	}
	if got.BuiltAt != 100 || got.Floor != trustrank.HandoffFloor || got.MaxHop != 4 || got.ViewBar != trustrank.DefaultViewBar {
		t.Fatalf("copy header: %+v", got)
	}
	var keys []string
	for _, r := range got.People {
		keys = append(keys, r[0].(string))
	}
	if strings.Join(keys, ",") != strings.Join([]string{trustHex(1), trustHex(2), trustHex(3)}, ",") {
		t.Fatalf("only ring 1 and people at or over the floor travel: %v", keys)
	}
	// A's own file is untouched: still whole.
	if whole, _ := trustrank.ReadResult(aDir, owner.pk); len(whole.People) != 5 || whole.Floor != 0 {
		t.Fatalf("the Haven's file changed: %+v", whole)
	}

	// Nothing new: 204, and the phone's file is not rewritten.
	before, _ := os.Stat(trustrank.ResultPath(bDir, owner.pk))
	if n := c.syncTrust(context.Background()); n != 0 {
		t.Fatalf("an unchanged result was copied again (%d)", n)
	}
	after, _ := os.Stat(trustrank.ResultPath(bDir, owner.pk))
	if !after.ModTime().Equal(before.ModTime()) {
		t.Fatal("the phone's copy was rewritten")
	}

	// A newer pass on the Haven: taken.
	writeTrustFile(t, aDir, owner.pk, 200)
	if n := c.syncTrust(context.Background()); n != 1 {
		t.Fatalf("a newer result was not copied (%d)", n)
	}
	if got, _ := trustrank.ReadResult(bDir, owner.pk); got.BuiltAt != 200 {
		t.Fatalf("copy is from %d", got.BuiltAt)
	}
}

// Who gets it: a paired device's token only, for an account this Haven
// ranks only, and never through the door's rules (tunnel, LAN).
func TestCopyTrustRankIsForPairedDevicesOnly(t *testing.T) {
	owner, aDir, _, s, url := trustPair(t, 100)
	token := copyPeerToken("npub1peer")
	q := "?account=" + owner.pk
	if resp := trustGet(t, url, q, token); resp.StatusCode != http.StatusOK {
		t.Fatalf("a paired device's token: %d", resp.StatusCode)
	}
	if resp := trustGet(t, url, q, ""); resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("no token: %d", resp.StatusCode)
	}
	if resp := trustGet(t, url, q, copyRandomHex(32)); resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("a made-up token: %d", resp.StatusCode)
	}
	// A file that is on disk for an account this Haven does not rank (left
	// by a removed account, say) is not handed out.
	other := newTestKey(t)
	writeTrustFile(t, aDir, other.pk, 100)
	if resp := trustGet(t, url, "?account="+other.pk, token); resp.StatusCode != http.StatusNotFound {
		t.Fatalf("an account this Haven does not rank: %d", resp.StatusCode)
	}
	for _, bad := range []string{"", "?account=..%2F..%2Fconfig", "?account=" + strings.ToUpper(owner.pk[:10]) + owner.pk[10:] + "0"} {
		if resp := trustGet(t, url, bad, token); resp.StatusCode != http.StatusNotFound {
			t.Fatalf("account %q: %d", bad, resp.StatusCode)
		}
	}
	if resp := trustGet(t, url, q+"&since=100", token); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("a device already holding this result: %d", resp.StatusCode)
	}
	// Only GET.
	req, _ := http.NewRequest(http.MethodPut, url+"/copy/v2/sync/trust"+q, strings.NewReader("{}"))
	req.Header.Set("Authorization", "Bearer "+token)
	if resp, err := http.DefaultClient.Do(req); err != nil || resp.StatusCode != http.StatusNotFound {
		t.Fatalf("a device must not be able to write the Haven's result: %v %v", resp, err)
	}
	// Through a public tunnel: nothing.
	req, _ = http.NewRequest(http.MethodGet, url+"/copy/v2/sync/trust"+q, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Cf-Connecting-Ip", "203.0.113.9")
	if resp, err := http.DefaultClient.Do(req); err != nil || resp.StatusCode != http.StatusNotFound {
		t.Fatalf("a tunnelled request: %v %v", resp, err)
	}
	// An unpaired device's token is dead at once.
	s.dropDevice(s.tokens[0].Device)
	if resp := trustGet(t, url, q, token); resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("after unpair: %d", resp.StatusCode)
	}
}

// A Haven with no result yet answers 404 and the catch-up still finishes.
func TestCopyCatchUpWithoutATrustRank(t *testing.T) {
	owner, _, bDir, _, url := trustPair(t, 0)
	if _, err := newCopyClient("npub1peer", url).sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(trustrank.ResultPath(bDir, owner.pk)); !os.IsNotExist(err) {
		t.Fatalf("a copy appeared from nothing: %v", err)
	}
}

// A device that ranks for itself (a Mac, a box) keeps its own result.
func TestCopyTrustRankNotTakenByADeviceThatRanks(t *testing.T) {
	owner, _, bDir, _, url := trustPair(t, 100)
	trustRankTakesCopy = func() bool { return false }
	if _, err := newCopyClient("npub1peer", url).sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(trustrank.ResultPath(bDir, owner.pk)); !os.IsNotExist(err) {
		t.Fatalf("a ranking device took a copy: %v", err)
	}
	if trustRankWanted("ios", "") || trustRankWanted("android", "") || !trustRankWanted("darwin", "") || !trustRankWanted("linux", "") {
		t.Fatal("phones take the copy; a Mac or a box ranks for itself")
	}
}

// What a device refuses from a Haven: another account's file, an older or
// unreadable one, rows that are not people. Its last good copy stays.
func TestCopyTrustRankRefusesABadCopy(t *testing.T) {
	owner := newTestKey(t)
	other := newTestKey(t)
	good := func() map[string]any {
		return map[string]any{"account": owner.pk, "builtAt": 300, "version": 2, "maxHop": 3, "viewBar": 55, "floor": 45,
			"people": []any{[]any{trustHex(2), 80.0, 2}}}
	}
	cases := map[string]func(m map[string]any){
		"another account":   func(m map[string]any) { m["account"] = other.pk },
		"older than held":   func(m map[string]any) { m["builtAt"] = 100 },
		"unknown version":   func(m map[string]any) { m["version"] = 3 },
		"score over 100":    func(m map[string]any) { m["people"] = []any{[]any{trustHex(2), 100.5, 2}} },
		"negative score":    func(m map[string]any) { m["people"] = []any{[]any{trustHex(2), -1.0, 2}} },
		"ring past maxHop":  func(m map[string]any) { m["people"] = []any{[]any{trustHex(2), 50.0, 4}} },
		"ring 0":            func(m map[string]any) { m["people"] = []any{[]any{trustHex(2), 50.0, 0}} },
		"maxHop past 6":     func(m map[string]any) { m["maxHop"] = 7 },
		"not a pubkey":      func(m map[string]any) { m["people"] = []any{[]any{"../../x", 50.0, 2}} },
		"a row of nonsense": func(m map[string]any) { m["people"] = []any{[]any{trustHex(2), "50", 2}} },
	}
	for name, breakIt := range cases {
		t.Run(name, func(t *testing.T) {
			m := good()
			breakIt(m)
			raw, _ := json.Marshal(m)
			var asked string
			ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				asked = r.URL.RawQuery
				w.Header().Set("Content-Type", "application/json")
				_, _ = w.Write(raw)
			}))
			defer ts.Close()
			openCopyVault(t, owner.pk)
			bDir := t.TempDir()
			prevDir, prevTakes := copyTrustKeepDir, trustRankTakesCopy
			copyTrustKeepDir = func() string { return bDir }
			trustRankTakesCopy = func() bool { return true }
			defer func() { copyTrustKeepDir, trustRankTakesCopy = prevDir, prevTakes }()
			writeTrustFile(t, bDir, owner.pk, 200)
			c := newCopyClient("npub1peer", ts.URL)
			if n := c.syncTrust(context.Background()); n != 0 {
				t.Fatalf("a bad copy was kept")
			}
			if asked != "account="+owner.pk+"&since=200" {
				t.Fatalf("asked %q", asked)
			}
			if kept, err := trustrank.ReadResult(bDir, owner.pk); err != nil || kept.BuiltAt != 200 {
				t.Fatalf("the last good copy must stay: %v %+v", err, kept)
			}
		})
	}
}

// The hand-off signs nothing: the request carries the bearer and no Nostr
// event, and the engine holds no account key to sign with.
func TestCopyTrustRankSignsNothing(t *testing.T) {
	owner := newTestKey(t)
	var auth []string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth = append(auth, r.Header.Get("Authorization"))
		http.NotFound(w, r)
	}))
	defer ts.Close()
	openCopyVault(t, owner.pk)
	prevTakes := trustRankTakesCopy
	trustRankTakesCopy = func() bool { return true }
	defer func() { trustRankTakesCopy = prevTakes }()
	c := newCopyClient("npub1peer", ts.URL)
	c.token = "tok"
	c.syncTrust(context.Background())
	if len(auth) != 1 || auth[0] != "Bearer tok" {
		t.Fatalf("the request must carry the device's copy token and nothing else: %v", auth)
	}
}
