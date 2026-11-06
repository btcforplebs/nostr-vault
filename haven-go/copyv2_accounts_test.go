//go:build !(js && wasm)

package main

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip19"
)

func npubOf(t *testing.T, hex string) string {
	t.Helper()
	n, err := nip19.EncodePublicKey(hex)
	if err != nil {
		t.Fatal(err)
	}
	return n
}

func TestCopyManifestAccountsFixtures(t *testing.T) {
	var fx struct {
		Owner    string
		Accounts []string
		Cases    []struct {
			Name     string
			Manifest copyManifest
			Expect   struct {
				OK    bool
				Error string
			}
		}
	}
	loadCopyFixture(t, "manifest-accounts-cases.json", &fx)
	if len(fx.Cases) < 6 {
		t.Fatalf("positive control: only %d cases read", len(fx.Cases))
	}
	mine := map[string]struct{}{}
	for _, a := range fx.Accounts {
		mine[a] = struct{}{}
	}
	for _, c := range fx.Cases {
		got := copyManifestError(c.Manifest, fx.Owner, mine)
		if (got == "") != c.Expect.OK || got != c.Expect.Error {
			t.Errorf("%s: got %q, want ok=%v error=%q", c.Name, got, c.Expect.OK, c.Expect.Error)
		}
	}
}

// Every accounts.json case, and above all: a key in accounts is refused.
func TestCopyAccountsRefuseFixtures(t *testing.T) {
	var fx struct {
		Cases []struct {
			Name   string
			File   json.RawMessage
			Expect string
		}
	}
	loadCopyFixture(t, "accounts-refuse-cases.json", &fx)
	keyCases := 0
	for _, c := range fx.Cases {
		_, got := copyAccountsRefusal(c.File)
		if got != c.Expect {
			t.Errorf("%s: got %q, want %q", c.Name, got, c.Expect)
		}
		if c.Expect == "secret_value" {
			keyCases++
		}
	}
	if len(fx.Cases) < 12 || keyCases < 3 {
		t.Fatalf("positive control: %d cases, %d with a key", len(fx.Cases), keyCases)
	}
}

func TestCopyAccountsMergeFixtures(t *testing.T) {
	var fx struct {
		Merge []struct {
			Name                 string
			Mine, Theirs, Expect []copyAccount
		}
		Shares []struct {
			Name         string
			Mine, Theirs []string
			Expect       bool
		}
	}
	loadCopyFixture(t, "accounts-merge-cases.json", &fx)
	if len(fx.Merge) < 3 || len(fx.Shares) < 2 {
		t.Fatal("positive control: cases missing")
	}
	for _, c := range fx.Merge {
		got := mergeCopyAccounts(c.Mine, c.Theirs)
		if !equalAccounts(got, c.Expect) {
			t.Errorf("%s: got %v, want %v", c.Name, got, c.Expect)
		}
	}
	for _, c := range fx.Shares {
		mine := map[string]struct{}{}
		for _, m := range c.Mine {
			mine[m] = struct{}{}
		}
		var theirs []string
		for _, n := range c.Theirs {
			h, ok := npubHex(n)
			if !ok {
				t.Fatalf("%s: %s is not an npub", c.Name, n)
			}
			theirs = append(theirs, h)
		}
		if got := copySharesAccount(mine, theirs); got != c.Expect {
			t.Errorf("%s: got %v", c.Name, got)
		}
	}
}

func equalAccounts(a, b []copyAccount) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// AddAccountsC's core: an account is own at once, for every reader, with no
// restart; readers run lock-free beside writers (run with -race); a new
// config ends the additions.
func TestLiveAccountsAreOwnAtOnceAndEndWithTheConfig(t *testing.T) {
	prev := config
	t.Cleanup(func() { config = prev; resetLiveAccounts() })
	owner, other := newTestKey(t), newTestKey(t)
	setupSyncConfig(owner.pk)
	resetLiveAccounts()
	if isOwnKey(other.pk) {
		t.Fatal("not added yet")
	}
	var wg sync.WaitGroup
	stop := make(chan struct{})
	for range 4 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-stop:
					return
				default:
					_ = isOwnKey(other.pk)
					for range whitelist() {
					}
				}
			}
		}()
	}
	for i := range 50 {
		k := newTestKey(t)
		if n := addLiveAccounts([]string{k.pk, owner.pk}); n != 1 {
			t.Fatalf("add %d: %d new, want 1 (the owner is already own)", i, n)
		}
	}
	addLiveAccounts([]string{other.pk})
	close(stop)
	wg.Wait()
	if !isOwnKey(other.pk) || !isOwnKey(owner.pk) {
		t.Fatal("added account (or the owner) is not own")
	}
	if len(whitelist()) != 52 {
		t.Fatalf("whitelist has %d keys, want 52", len(whitelist()))
	}
	if _, inBase := config.WhitelistedPubKeys[other.pk]; inBase {
		t.Fatal("the loaded config was written to")
	}
	resetLiveAccounts()
	if isOwnKey(other.pk) {
		t.Fatal("a new config still had a live account")
	}
}

// writeAccountsZip: a backup zip with accounts.json and one outbox note.
func writeAccountsZip(t *testing.T, accounts string, note nostr.Event) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "backup.zip")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	zw := zip.NewWriter(f)
	if accounts != "" {
		w, _ := zw.Create(copyAccountsEntry)
		_, _ = w.Write([]byte(accounts))
	}
	w, _ := zw.Create("outbox.jsonl")
	line, _ := json.Marshal(note)
	_, _ = w.Write(append(line, '\n'))
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	_ = f.Close()
	return path
}

// A restore takes a zip that shares one of this vault's accounts, makes its
// other accounts own and keeps their notes; refuses one sharing none; and
// refuses one with a key in accounts, adding nothing.
func TestRestoreTakesSharedAccountsAndRefusesKeys(t *testing.T) {
	me, them, stranger := newTestKey(t), newTestKey(t), newTestKey(t)
	openCopyVault(t, me.pk)
	t.Cleanup(resetLiveAccounts)
	theirNote := them.sign(t, nostr.Event{Kind: 1, Content: "their note"})

	// A key where an npub goes: refused, nothing added, nothing restored.
	keyed := `{"v":1,"updated_at":1,"accounts":[{"npub":"` + npubOf(t, me.pk) + `"},{"npub":"` + them.pk + `"}]}`
	if err := importFromZip(context.Background(), writeAccountsZip(t, keyed, theirNote)); !errors.Is(err, errAccountsRefused) {
		t.Fatalf("a key in accounts: %v, want errAccountsRefused", err)
	}
	if isOwnKey(them.pk) || countIn(t, outboxDB, nostr.Filter{IDs: []string{theirNote.ID}}) != 0 {
		t.Fatal("a refused accounts list still added an account or a note")
	}

	// Sharing none of mine: not my backup.
	none := `{"v":1,"updated_at":1,"accounts":[{"npub":"` + npubOf(t, them.pk) + `"},{"npub":"` + npubOf(t, stranger.pk) + `"}]}`
	if err := importFromZip(context.Background(), writeAccountsZip(t, none, theirNote)); !errors.Is(err, errNotYourBackup) {
		t.Fatalf("no shared account: %v, want errNotYourBackup", err)
	}

	// Sharing me: theirs become mine before the stores, so their note stays.
	shared := `{"v":1,"updated_at":1,"accounts":[{"npub":"` + npubOf(t, them.pk) + `","name":"Them"},{"npub":"` + npubOf(t, me.pk) + `"}]}`
	if err := importFromZip(context.Background(), writeAccountsZip(t, shared, theirNote)); err != nil {
		t.Fatalf("shared account: %v", err)
	}
	if !isOwnKey(them.pk) {
		t.Fatal("their account is not own after the restore")
	}
	if countIn(t, outboxDB, nostr.Filter{IDs: []string{theirNote.ID}}) != 1 {
		t.Fatal("the other account's note was dropped")
	}
	raw, err := os.ReadFile(copyAccountsFile)
	if err != nil || !strings.Contains(string(raw), npubOf(t, them.pk)) || !strings.Contains(string(raw), `"Them"`) {
		t.Fatalf("copy-accounts.json for the app: %s %v", raw, err)
	}
	for _, secret := range []string{me.pk, them.pk} {
		if strings.Contains(string(raw), secret) {
			t.Fatal("copy-accounts.json holds a hex key")
		}
	}
}

// The copy: A (owner X, with L as an account) to B (owner L). B shares L, so
// it takes the copy, X becomes one of B's accounts before the stores, and X's
// notes are kept, not skipped (Tim's 22,412 skipped on 2026-11-06).
func TestCopyBringsTheOtherAccountsAndTheirNotes(t *testing.T) {
	x, l := newTestKey(t), newTestKey(t)
	t.Cleanup(resetLiveAccounts)

	// A
	openCopyVault(t, x.pk)
	config.WhitelistedPubKeys = map[string]struct{}{x.pk: {}, l.pk: {}}
	xNote := x.sign(t, nostr.Event{Kind: 1, Content: "x's note"})
	lNote := l.sign(t, nostr.Event{Kind: 1, Content: "l's note"})
	saveEv(t, outboxDB, xNote)
	saveEv(t, outboxDB, lNote)
	appFile := `{"v":1,"updated_at":5,"accounts":[{"npub":"` + npubOf(t, x.pk) + `","name":"X"},{"npub":"` + npubOf(t, l.pk) + `","name":"L"}]}`
	if err := os.WriteFile(copyAccountsFile, []byte(appFile), 0o600); err != nil {
		t.Fatal(err)
	}
	srcDir := t.TempDir()
	built, err := buildCopy(context.Background(), srcDir, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", func(copyProgress) {})
	if err != nil {
		t.Fatal(err)
	}
	if len(built.Accounts) != 2 || built.Accounts[0] != npubOf(t, x.pk) {
		t.Fatalf("manifest accounts = %v, want owner first, both", built.Accounts)
	}
	if names := zipNames(t, filepath.Join(srcDir, "notes.zip")); names[copyAccountsEntry] == nil {
		t.Fatal("notes.zip has no accounts.json")
	}
	zr, _ := zip.OpenReader(filepath.Join(srcDir, "notes.zip"))
	if zr.File[0].Name != copyAccountsEntry {
		t.Fatalf("first entry is %s, want accounts.json before the stores", zr.File[0].Name)
	}
	zr.Close()

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
	defer ts.Close()

	// B: L's vault, nothing of X's.
	openCopyVault(t, l.pk)
	copyPollEvery = 10 * time.Millisecond
	t.Cleanup(func() { copyPollEvery = 2 * time.Second })
	var logs bytes.Buffer
	captureLog(t, &logs)
	c := newCopyClient("npub1peer", ts.URL)
	c.free = func(string) (uint64, bool) { return 1 << 40, true }
	// One process plays both: A's start check reads the live config, which
	// is B's now, so the proof is by B's owner. The start rules have their
	// own tests (TestCopyStartAuth); this one is about B's side.
	if err := c.run(context.Background(), startProof(t, l, nostr.Now(), "/copy/v2/start")); err != nil {
		t.Fatalf("copy: %v\n%s", err, logs.String())
	}
	if !isOwnKey(x.pk) {
		t.Fatal("X is not one of B's accounts after the copy")
	}
	if countIn(t, outboxDB, nostr.Filter{IDs: []string{xNote.ID}}) != 1 {
		t.Fatal("X's note was skipped")
	}
	if countIn(t, outboxDB, nostr.Filter{IDs: []string{lNote.ID}}) != 1 {
		t.Fatal("L's note did not arrive")
	}
	raw, _ := os.ReadFile(copyAccountsFile)
	if !strings.Contains(string(raw), `"X"`) {
		t.Fatalf("B's app was not told about X with its name: %s", raw)
	}
}

// Catch-up: B takes A's accounts and sends its own; A's side merges B's.
// Both only add.
func TestCatchUpMergesAccountsNeverRemoves(t *testing.T) {
	me, a2, b2 := newTestKey(t), newTestKey(t), newTestKey(t)
	t.Cleanup(resetLiveAccounts)
	aList := `{"v":1,"updated_at":9,"accounts":[{"npub":"` + npubOf(t, me.pk) + `"},{"npub":"` + npubOf(t, a2.pk) + `","name":"A2"}]}`
	var put []byte
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/copy/v2/sync/accounts" {
			http.NotFound(w, r)
			return
		}
		if r.Method == http.MethodPut {
			put, _ = io.ReadAll(r.Body)
			copyJSON(w, http.StatusOK, map[string]string{"accounts": "added"})
			return
		}
		_, _ = w.Write([]byte(aList))
	}))
	defer ts.Close()

	// B: me, plus b2 added live (AddAccountsC).
	openCopyVault(t, me.pk)
	resetLiveAccounts()
	addLiveAccounts([]string{b2.pk})
	_ = os.WriteFile(copyAccountsFile, []byte(`{"v":1,"updated_at":3,"accounts":[{"npub":"`+npubOf(t, b2.pk)+`","name":"B2"}]}`), 0o600)
	c := newCopyClient("npub1peer", ts.URL)
	c.token = "t"
	got, err := c.syncAccounts(context.Background())
	if err != nil || got != "added" {
		t.Fatalf("B took A's accounts: %q %v", got, err)
	}
	for name, k := range map[string]string{"me": me.pk, "a2": a2.pk, "b2": b2.pk} {
		if !isOwnKey(k) {
			t.Fatalf("B is missing %s after the catch-up", name)
		}
	}
	raw, _ := os.ReadFile(copyAccountsFile)
	if !strings.Contains(string(raw), `"B2"`) || !strings.Contains(string(raw), `"A2"`) {
		t.Fatalf("B's app file lost or missed an account: %s", raw)
	}
	if !strings.Contains(string(put), npubOf(t, b2.pk)) {
		t.Fatalf("B did not send its own accounts: %s", put)
	}

	// A's side of the PUT: merged into A's, nothing of A's removed.
	openCopyVault(t, me.pk)
	resetLiveAccounts()
	config.WhitelistedPubKeys = map[string]struct{}{me.pk: {}, a2.pk: {}}
	_ = os.WriteFile(copyAccountsFile, []byte(aList), 0o600)
	if why := takeCopyAccounts(put); why != "added" {
		t.Fatalf("A took B's accounts: %q", why)
	}
	if !isOwnKey(b2.pk) || !isOwnKey(a2.pk) {
		t.Fatal("A did not merge B's account, or lost its own")
	}
	raw, _ = os.ReadFile(copyAccountsFile)
	if !strings.Contains(string(raw), `"A2"`) || !strings.Contains(string(raw), npubOf(t, b2.pk)) {
		t.Fatalf("A's app file: %s", raw)
	}
}
