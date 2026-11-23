//go:build !(js && wasm)

package main

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/barrydeen/haven/pkg/trustrank"
)

func statusGet(t *testing.T, url, bearer string) (*http.Response, vaultStatus) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, url+"/copy/v2/sync/status", nil)
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var st vaultStatus
	if resp.StatusCode == http.StatusOK {
		if err := json.NewDecoder(resp.Body).Decode(&st); err != nil {
			t.Fatal(err)
		}
	}
	return resp, st
}

// The state line: off where it never ranks, paused with the reason, running
// only while a pass is live and allowed, idle otherwise.
func TestVaultStatusStates(t *testing.T) {
	dir := t.TempDir()
	prev := vaultMarksDir
	vaultMarksDir = func() string { return dir }
	t.Cleanup(func() { vaultMarksDir = prev; vaultPassEnd() })
	acct := trustHex(9)
	now := time.Unix(1000, 0)
	if s := buildVaultStatus(dir, []string{acct}, now, false, "", nil); s.State != "off" {
		t.Fatalf("a phone: %s", s.State)
	}
	if s := buildVaultStatus(dir, []string{acct}, now, true, "", nil); s.State != "idle" || len(s.Accounts) != 1 || s.Accounts[0].Result != nil {
		t.Fatalf("nothing running: %+v", s)
	}
	if s := buildVaultStatus(dir, []string{acct}, now, true, "app", nil); s.State != "paused" || s.PausedWhy != "app" {
		t.Fatalf("window open: %+v", s)
	}
	vaultPassBegin(acct, false)
	vaultPassProgress(2, 10, 40)
	vaultPassProgress(2, 11, 40)
	s := buildVaultStatus(dir, []string{acct}, now, true, "", nil)
	a := s.Accounts[0]
	if s.State != "running" || !a.Running || a.Ring != 2 || a.RingDone != 11 || a.RingTotal != 40 || a.ListsRead != 2 {
		t.Fatalf("running: %+v %+v", s, a)
	}
	// Paused mid-pass (the crawler stops at its next Wait): not running.
	if s := buildVaultStatus(dir, []string{acct}, now, true, "busy", nil); s.State != "paused" || s.Accounts[0].Running {
		t.Fatalf("busy: %+v", s)
	}
	vaultPassEnd()
	if s := buildVaultStatus(dir, []string{acct}, now, true, "", nil); s.State != "idle" || s.Accounts[0].Running {
		t.Fatalf("after the pass: %+v", s)
	}
}

func TestVaultPausedWhy(t *testing.T) {
	if vaultPausedWhy(true, false, false) != "app" || vaultPausedWhy(true, true, true) != "busy" ||
		vaultPausedWhy(false, false, false) != "" || vaultPausedWhy(true, true, false) != "" {
		t.Fatal("paused reasons wrong")
	}
}

// Finished pass, result counts, distant fetch and a pass cut halfway, all
// from what the jobs keep.
func TestVaultStatusAfterAPass(t *testing.T) {
	dir := t.TempDir()
	prev := vaultMarksDir
	vaultMarksDir = func() string { return dir }
	t.Cleanup(func() { vaultMarksDir = prev })
	acct := trustHex(9)
	writeTrustFile(t, dir, acct, 500)
	if err := trustrank.SaveState(dir, trustrank.State{Account: acct, Hop: 1, FullAt: 400, RefreshAt: 450}); err != nil {
		t.Fatal(err)
	}
	vaultDistantFetched(acct, 120, 7)
	a := buildVaultStatus(dir, []string{acct}, time.Unix(1000, 0), true, "", nil).Accounts[0]
	if a.FinishedAt != 450 || a.FullAt != 400 || a.Cut {
		t.Fatalf("pass times: %+v", a)
	}
	if a.Result == nil || a.Result.BuiltAt != 500 || a.Result.People != 5 || a.DistantAtBar != 0 || a.Result.DistantByShown[0] != 1 {
		t.Fatalf("result: %+v", a.Result)
	}
	if a.DistantFetchAt == 0 || a.DistantFetchPeople != 120 || a.DistantFetchNew != 7 {
		t.Fatalf("distant: %+v", a)
	}
	if err := trustrank.SaveState(dir, trustrank.State{Account: acct, Hop: 3, Next: 17, Last: trustHex(2), FullAt: 400}); err != nil {
		t.Fatal(err)
	}
	if a := buildVaultStatus(dir, []string{acct}, time.Unix(1000, 0), true, "app", nil).Accounts[0]; !a.Cut || a.Ring != 3 || a.RingDone != 17 {
		t.Fatalf("cut pass: %+v", a)
	}
}

// Over the mesh: a paired device's token reads the status, sees its own
// hand-off, and nobody else reads anything.
func TestVaultStatusOverTheMesh(t *testing.T) {
	owner, aDir, _, s, url := trustPair(t, 100)
	prev := vaultMarksDir
	vaultMarksDir = func() string { return aDir }
	t.Cleanup(func() { vaultMarksDir = prev })
	device := s.tokens[0].Device
	c := newCopyClient("npub1peer", url)
	if _, err := c.sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	token := copyPeerToken("npub1peer")
	resp, st := statusGet(t, url, token)
	if resp.StatusCode != http.StatusOK || len(st.Accounts) != 1 || st.Accounts[0].Account != owner.pk {
		t.Fatalf("status: %d %+v", resp.StatusCode, st)
	}
	hs := st.Accounts[0].Handoffs
	if len(hs) != 1 || hs[0].Device != device || hs[0].BuiltAt != 100 || hs[0].TookAt == 0 || hs[0].CheckedAt == 0 {
		t.Fatalf("hand-offs: %+v", hs)
	}
	if st.Accounts[0].Result == nil || st.Accounts[0].Result.People != 5 {
		t.Fatalf("result: %+v", st.Accounts[0].Result)
	}
	if resp, _ := statusGet(t, url, ""); resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("no token: %d", resp.StatusCode)
	}
	if resp, _ := statusGet(t, url, copyRandomHex(32)); resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("a made-up token: %d", resp.StatusCode)
	}
	req, _ := http.NewRequest(http.MethodGet, url+"/copy/v2/sync/status", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Cf-Connecting-Ip", "203.0.113.9")
	if resp, err := http.DefaultClient.Do(req); err != nil || resp.StatusCode != http.StatusNotFound {
		t.Fatalf("a tunnelled request: %v %v", resp, err)
	}
	req, _ = http.NewRequest(http.MethodPost, url+"/copy/v2/sync/status", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	if resp, err := http.DefaultClient.Do(req); err != nil || resp.StatusCode != http.StatusNotFound {
		t.Fatalf("only GET: %v %v", resp, err)
	}
	// Unpaired: its token is dead, and its hand-off is not listed to others.
	if err := meshDevices.set(`{"self":"` + meshDevices.selfKey() + `","devices":[]}`); err != nil {
		t.Fatal(err)
	}
	if resp, _ := statusGet(t, url, token); resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("after unpair: %d", resp.StatusCode)
	}
	if a := readVaultStatus().Accounts; len(a) != 1 || len(a[0].Handoffs) != 0 {
		t.Fatalf("an unpaired device's hand-off is still listed: %+v", a)
	}
}
