//go:build !(js && wasm)

package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/barrydeen/haven/pkg/trustrank"
)

// Tron's #2409 low (a): a device that is up to date gets its 204 from the
// start of the file. Here the rows are cut off, so a whole read would fail
// (404); the 204 shows the rows were never read.
func TestCopyTrustNoChangeReadsOnlyTheHeader(t *testing.T) {
	owner, aDir, _, _, url := trustPair(t, 100)
	token := copyPeerToken("npub1peer")
	cut := `{"account":"` + owner.pk + `","builtAt":100,"version":2,"maxHop":4,"people":[["` + trustHex(2) + `",80,2],[`
	if err := os.WriteFile(trustrank.ResultPath(aDir, owner.pk), []byte(cut), 0o600); err != nil {
		t.Fatal(err)
	}
	q := "?account=" + owner.pk
	if resp := trustGet(t, url, q+"&since=100", token); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("an up-to-date device: %d", resp.StatusCode)
	}
	if resp := trustGet(t, url, q+"&since=99", token); resp.StatusCode != http.StatusNotFound {
		t.Fatalf("a device that needs the rows must not get a broken file: %d", resp.StatusCode)
	}
}

// twoAccounts: this device has owner x and a second signed-in account l,
// as the app's account file and the whitelist say. Returns a function that
// signs l out (the app rewrites its file and drops l from the whitelist).
func twoAccounts(t *testing.T, x, l testKey) (signOutL func()) {
	t.Helper()
	t.Cleanup(resetLiveAccounts)
	config.WhitelistedPubKeys = map[string]struct{}{x.pk: {}, l.pk: {}}
	both := `{"v":1,"updated_at":5,"accounts":[{"npub":"` + npubOf(t, x.pk) + `","name":"X"},{"npub":"` + npubOf(t, l.pk) + `","name":"L"}]}`
	if err := os.WriteFile(copyAccountsFile, []byte(both), 0o600); err != nil {
		t.Fatal(err)
	}
	return func() {
		delete(config.WhitelistedPubKeys, l.pk)
		only := `{"v":1,"updated_at":6,"accounts":[{"npub":"` + npubOf(t, x.pk) + `","name":"X"}]}`
		if err := os.WriteFile(copyAccountsFile, []byte(only), 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

func exists(t *testing.T, path string) bool {
	t.Helper()
	_, err := os.Stat(path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		t.Fatal(err)
	}
	return err == nil
}

// Tron's #2409 low (c), phone: the next catch-up after an account signs out
// removes that account's copy; the other account's stays.
func TestCopyTrustCopyGoesWhenItsAccountSignsOut(t *testing.T) {
	x, l := newTestKey(t), newTestKey(t)
	openCopyVault(t, x.pk)
	signOutL := twoAccounts(t, x, l)
	bDir := t.TempDir()
	prevDir, prevTakes := copyTrustKeepDir, trustRankTakesCopy
	copyTrustKeepDir = func() string { return bDir }
	trustRankTakesCopy = func() bool { return true }
	t.Cleanup(func() { copyTrustKeepDir, trustRankTakesCopy = prevDir, prevTakes })
	writeTrustFile(t, bDir, x.pk, 100)
	writeTrustFile(t, bDir, l.pk, 100)
	ts := httptest.NewServer(http.NotFoundHandler()) // a Haven with nothing new
	t.Cleanup(ts.Close)
	c := newCopyClient("npub1peer", ts.URL)

	c.syncTrust(context.Background())
	if !exists(t, trustrank.ResultPath(bDir, l.pk)) || !exists(t, trustrank.ResultPath(bDir, x.pk)) {
		t.Fatal("while both are signed in, both copies stay")
	}
	signOutL()
	c.syncTrust(context.Background())
	if exists(t, trustrank.ResultPath(bDir, l.pk)) {
		t.Fatal("the signed-out account's copy must go")
	}
	if !exists(t, trustrank.ResultPath(bDir, x.pk)) {
		t.Fatal("the signed-in account's copy must stay")
	}
}

// With no readable account file the account list is the owner alone (fail
// closed), which says nothing about the others: nothing is removed.
func TestCopyTrustNothingRemovedWithoutTheAccountFile(t *testing.T) {
	x, l := newTestKey(t), newTestKey(t)
	openCopyVault(t, x.pk)
	twoAccounts(t, x, l)
	dir := t.TempDir()
	writeTrustFile(t, dir, l.pk, 100)
	for name, body := range map[string]*string{"missing": nil, "unreadable": ptr(`{"accounts":"nsec1qqq"}`)} {
		_ = os.Remove(copyAccountsFile)
		if body != nil {
			if err := os.WriteFile(copyAccountsFile, []byte(*body), 0o600); err != nil {
				t.Fatal(err)
			}
		}
		pruneTrustRank(dir)
		if !exists(t, trustrank.ResultPath(dir, l.pk)) {
			t.Fatalf("%s account file: a copy was removed on a guess", name)
		}
	}
}

func ptr(s string) *string { return &s }

// Tron's #2409 low (c), Mac or box: the ranking job removes a signed-out
// account's own result and checkpoint, at start and every round.
func TestTrustRankJobRemovesASignedOutAccountsResult(t *testing.T) {
	x, l := newTestKey(t), newTestKey(t)
	openCopyVault(t, x.pk)
	signOutL := twoAccounts(t, x, l)
	dir := t.TempDir()
	config.WotCachePath = filepath.Join(dir, "wot_cache.json")
	writeTrustFile(t, dir, x.pk, 100)
	writeTrustFile(t, dir, l.pk, 100)
	if err := trustrank.SaveState(dir, trustrank.State{Account: l.pk, Hop: 2}); err != nil {
		t.Fatal(err)
	}
	signOutL()
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // only the start-up step runs
	runTrustRank(ctx, nil, true)
	if exists(t, trustrank.ResultPath(dir, l.pk)) || exists(t, trustrank.StatePath(dir, l.pk)) {
		t.Fatal("the signed-out account's result and checkpoint must go")
	}
	if !exists(t, trustrank.ResultPath(dir, x.pk)) {
		t.Fatal("the signed-in account's result must stay")
	}
}
