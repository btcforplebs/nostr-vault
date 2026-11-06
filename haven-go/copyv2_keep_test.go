//go:build !(js && wasm)

package main

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// buildAndServeCopy builds A's copy (the live config is A's) and serves it.
func buildAndServeCopy(t *testing.T) (*httptest.Server, string) {
	t.Helper()
	srcDir := t.TempDir()
	built, err := buildCopy(context.Background(), srcDir, "cccccccccccccccccccccccccccccccc", func(copyProgress) {})
	if err != nil {
		t.Fatal(err)
	}
	aWD, _ := os.Getwd()
	s := newTestCopyServer(func(dir, id string, p copyBuildProgress) (copyManifest, error) {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return copyManifest{}, err
		}
		for _, n := range []string{"notes.zip", "media.zip"} {
			raw, err := os.ReadFile(filepath.Join(srcDir, n))
			if err != nil {
				return copyManifest{}, err
			}
			if err := os.WriteFile(filepath.Join(dir, n), raw, 0o600); err != nil {
				return copyManifest{}, err
			}
		}
		m := built
		m.ID = id
		return m, nil
	})
	s.cacheDir = filepath.Join(aWD, copyCacheDir)
	ts := httptest.NewServer(s)
	t.Cleanup(ts.Close)
	return ts, srcDir
}

// Logen, 2026-11-06 (iPad <- Mac, build 10): a look-only account on A (in
// its whitelist, not a signing account, so not in accounts.json) lost every
// note and inbox event in the copy. The keep list carries it: B keeps its
// events read only (brought over) and neither offers nor adds it.
func TestCopyKeepsLookOnlyAccountsEventsReadOnly(t *testing.T) {
	owner, look, stranger := newTestKey(t), newTestKey(t), newTestKey(t)
	t.Cleanup(resetLiveAccounts)

	// A: owner signs; look is look-only (own, not in the app's file).
	openCopyVault(t, owner.pk)
	config.WhitelistedPubKeys = map[string]struct{}{owner.pk: {}, look.pk: {}}
	ownNote := owner.sign(t, nostr.Event{Kind: 1, Content: "owner's note"})
	lookNote := look.sign(t, nostr.Event{Kind: 1, Content: "look's note"})
	lookReply := stranger.sign(t, nostr.Event{Kind: 1, Content: "to look", Tags: nostr.Tags{{"p", look.pk}}})
	strangerNote := stranger.sign(t, nostr.Event{Kind: 1, Content: "nobody's"})
	saveEv(t, outboxDB, ownNote)
	saveEv(t, outboxDB, lookNote)
	saveEv(t, inboxDB, lookReply)
	app := `{"v":1,"updated_at":5,"accounts":[{"npub":"` + npubOf(t, owner.pk) + `","name":"Me"}]}`
	if err := os.WriteFile(copyAccountsFile, []byte(app), 0o600); err != nil {
		t.Fatal(err)
	}
	ts, srcDir := buildAndServeCopy(t)

	// A's zip: accounts.json signing only, keep.json every account, no names.
	zr, err := zip.OpenReader(filepath.Join(srcDir, "notes.zip"))
	if err != nil {
		t.Fatal(err)
	}
	if zr.File[0].Name != copyAccountsEntry || zr.File[1].Name != copyKeepEntry {
		t.Fatalf("entries start %s, %s; want accounts.json, keep.json", zr.File[0].Name, zr.File[1].Name)
	}
	read := func(f *zip.File) copyAccountList {
		rc, _ := f.Open()
		defer rc.Close()
		var l copyAccountList
		if err := json.NewDecoder(rc).Decode(&l); err != nil {
			t.Fatal(err)
		}
		return l
	}
	if acc := read(zr.File[0]).hexes(); len(acc) != 1 || acc[0] != owner.pk {
		t.Fatalf("accounts.json = %v, want the owner only", acc)
	}
	keepList := read(zr.File[1])
	if k := keepList.hexes(); len(k) != 2 || k[0] != owner.pk || k[1] != look.pk {
		t.Fatalf("keep.json = %v, want owner then look", k)
	}
	for _, a := range keepList.Accounts {
		if a.Name != "" {
			t.Fatalf("keep.json carries a name: %v", a)
		}
	}
	zr.Close()

	// B: the same owner's other device, nothing of look's.
	openCopyVault(t, owner.pk)
	copyPollEvery = 10 * time.Millisecond
	t.Cleanup(func() { copyPollEvery = 2 * time.Second })
	var logs bytes.Buffer
	captureLog(t, &logs)
	c := newCopyClient("npub1peer", ts.URL)
	c.free = func(string) (uint64, bool) { return 1 << 40, true }
	if err := c.run(context.Background(), startProof(t, owner, nostr.Now(), "/copy/v2/start")); err != nil {
		t.Fatalf("copy: %v\n%s", err, logs.String())
	}
	if countIn(t, outboxDB, nostr.Filter{IDs: []string{lookNote.ID}}) != 1 {
		t.Fatal("the look-only account's note was skipped")
	}
	if countIn(t, inboxDB, nostr.Filter{IDs: []string{lookReply.ID}}) != 1 {
		t.Fatal("the look-only account's inbox event was skipped")
	}
	if countIn(t, outboxDB, nostr.Filter{IDs: []string{ownNote.ID}}) != 1 {
		t.Fatal("the owner's note did not arrive")
	}
	if countIn(t, outboxDB, nostr.Filter{IDs: []string{strangerNote.ID}}) != 0 {
		t.Fatal("a stranger's note got into the outbox")
	}
	if isOwnKey(look.pk) {
		t.Fatal("the copy added the look-only account")
	}
	if _, b := broughtAccounts()[look.pk]; !b {
		t.Fatal("the look-only account is not read only (not recorded as brought over)")
	}
	if _, b := broughtAccounts()[owner.pk]; b {
		t.Fatal("the owner was recorded as brought over")
	}
	raw, _ := os.ReadFile(copyAccountsFile)
	if strings.Contains(string(raw), npubOf(t, look.pk)) {
		t.Fatalf("the look-only account was offered: %s", raw)
	}
}

// A keep list that fails §3.4 refuses the whole copy (nothing restored),
// as accounts.json does; no keep list (an older A) restores as before.
func TestCheckZipKeepRefusesSecretsAndReadsOlderZips(t *testing.T) {
	owner, look := newTestKey(t), newTestKey(t)
	openCopyVault(t, owner.pk)
	mk := func(keep string) string {
		p := filepath.Join(t.TempDir(), "notes.zip")
		f, _ := os.Create(p)
		zw := zip.NewWriter(f)
		_ = writeZipAccounts(zw, []byte(`{"v":1,"accounts":[{"npub":"`+npubOf(t, owner.pk)+`"}]}`))
		if keep != "" {
			_ = writeZipEntry(zw, copyKeepEntry, []byte(keep))
		}
		zw.Close()
		f.Close()
		return p
	}
	if k, err := checkZipKeep(mk("")); err != nil || k != nil {
		t.Fatalf("no keep.json: %v, %v; want nil, nil", k, err)
	}
	good := `{"v":1,"accounts":[{"npub":"` + npubOf(t, owner.pk) + `"},{"npub":"` + npubOf(t, look.pk) + `"}]}`
	if k, err := checkZipKeep(mk(good)); err != nil || len(k) != 2 || k[1] != look.pk {
		t.Fatalf("good keep.json: %v, %v", k, err)
	}
	for name, bad := range map[string]string{
		"secret":  `{"v":1,"accounts":[{"npub":"` + npubOf(t, look.pk) + `","nsec":"` + look.sk + `"}]}`,
		"hex":     `{"v":1,"accounts":[{"npub":"` + look.pk + `"}]}`,
		"version": `{"v":2,"accounts":[{"npub":"` + npubOf(t, look.pk) + `"}]}`,
		"empty":   `{"v":1,"accounts":[]}`,
	} {
		if _, err := checkZipKeep(mk(bad)); !errors.Is(err, errAccountsRefused) {
			t.Fatalf("%s keep.json: err %v, want refused", name, err)
		}
	}
}
