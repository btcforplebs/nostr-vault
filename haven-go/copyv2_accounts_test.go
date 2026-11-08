//go:build !(js && wasm)

package main

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"github.com/fiatjaf/eventstore"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
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

// writeAccountsZip: a backup zip with accounts.json and outbox notes.
func writeAccountsZip(t *testing.T, accounts string, notes ...nostr.Event) string {
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
	for _, note := range notes {
		line, _ := json.Marshal(note)
		_, _ = w.Write(append(line, '\n'))
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	_ = f.Close()
	return path
}

// A backup restore (Settings, setup, cloud) takes a zip that shares one of
// this vault's accounts, keeps every event it carries for every account in
// its list, and neither adds nor offers any of them: only a linked-device
// copy offers (Logen, 2026-11-06). Refuses one sharing none, and one with a
// key in accounts, keeping nothing.
func TestRestoreKeepsEveryAccountsEventsAndAddsNone(t *testing.T) {
	me, them, stranger := newTestKey(t), newTestKey(t), newTestKey(t)
	openCopyVault(t, me.pk)
	t.Cleanup(resetLiveAccounts)
	theirNote := them.sign(t, nostr.Event{Kind: 1, Content: "their note"})

	// A key where an npub goes: refused, nothing added, nothing restored.
	keyed := `{"v":1,"updated_at":1,"accounts":[{"npub":"` + npubOf(t, me.pk) + `"},{"npub":"` + them.pk + `"}]}`
	var logs bytes.Buffer
	captureLog(t, &logs)
	if err := importFromZip(context.Background(), writeAccountsZip(t, keyed, theirNote)); !errors.Is(err, errAccountsRefused) {
		t.Fatalf("a key in accounts: %v, want errAccountsRefused", err)
	}
	if !strings.Contains(logs.String(), "accounts refused") || !strings.Contains(logs.String(), "secret_value") {
		t.Fatalf("the refusal was not logged: %q", logs.String())
	}
	if isOwnKey(them.pk) || countIn(t, outboxDB, nostr.Filter{IDs: []string{theirNote.ID}}) != 0 {
		t.Fatal("a refused accounts list still added an account or a note")
	}

	// Sharing none of mine: not my backup.
	none := `{"v":1,"updated_at":1,"accounts":[{"npub":"` + npubOf(t, them.pk) + `"},{"npub":"` + npubOf(t, stranger.pk) + `"}]}`
	if err := importFromZip(context.Background(), writeAccountsZip(t, none, theirNote)); !errors.Is(err, errNotYourBackup) {
		t.Fatalf("no shared account: %v, want errNotYourBackup", err)
	}

	// Sharing me: restored, their note kept, their account neither added nor offered.
	shared := `{"v":1,"updated_at":1,"accounts":[{"npub":"` + npubOf(t, them.pk) + `","name":"Them"},{"npub":"` + npubOf(t, me.pk) + `"}]}`
	myNote := me.sign(t, nostr.Event{Kind: 1, Content: "my note"})
	zipPath := writeAccountsZip(t, shared, theirNote, myNote)
	if err := importFromZip(context.Background(), zipPath); err != nil {
		t.Fatalf("shared account: %v", err)
	}
	if isOwnKey(them.pk) {
		t.Fatal("a backup zip made a stranger's key own")
	}
	if countIn(t, outboxDB, nostr.Filter{IDs: []string{theirNote.ID}}) != 1 {
		t.Fatal("the other account's note was dropped: adding it later would find nothing")
	}
	if countIn(t, outboxDB, nostr.Filter{IDs: []string{myNote.ID}}) != 1 {
		t.Fatal("my own note was not restored")
	}
	if raw, err := os.ReadFile(copyAccountsFile); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("a backup zip offered accounts to the app: %s %v", raw, err)
	}
}

// A stranger's backup zip that names the owner's npub (Tron, Logen
// 2026-11-06): every event it holds is stored, in case that account signs in
// later, but none is uploaded, none is served on the public outbox (relay
// reads, the public page, mesh photos), and no account is offered. The
// vault's own reads still see them; the owner's own zip is unchanged.
func TestStrangerZipIsStoredNeverUploadedServedOrOffered(t *testing.T) {
	me, stranger := newTestKey(t), newTestKey(t)
	openCopyVault(t, me.pk)
	t.Cleanup(resetLiveAccounts)
	photo := strings.Repeat("ab", 32)
	now := nostr.Now()
	strangerNote := stranger.sign(t, nostr.Event{Kind: 1, CreatedAt: now, Content: "https://cdn.example/" + photo + ".jpg"})
	strangerFollows := stranger.sign(t, nostr.Event{Kind: nostr.KindFollowList, CreatedAt: now})
	myNote := me.sign(t, nostr.Event{Kind: 1, CreatedAt: now, Content: "mine"})
	accounts := `{"v":1,"updated_at":1,"accounts":[{"npub":"` + npubOf(t, stranger.pk) + `","name":"Stranger"},{"npub":"` + npubOf(t, me.pk) + `"}]}`
	if err := importFromZip(context.Background(), writeAccountsZip(t, accounts, strangerNote, strangerFollows, myNote)); err != nil {
		t.Fatalf("stranger zip naming the owner: %v", err)
	}

	// Stored.
	theirs := nostr.Filter{IDs: []string{strangerNote.ID, strangerFollows.ID}}
	if countIn(t, outboxDB, theirs) != 2 || countIn(t, outboxDB, nostr.Filter{IDs: []string{myNote.ID}}) != 1 {
		t.Fatal("the zip's events were not all stored")
	}
	// 0 accounts offered or added.
	if isOwnKey(stranger.pk) {
		t.Fatal("a backup zip made the stranger's key own")
	}
	if raw, err := os.ReadFile(copyAccountsFile); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("a backup zip offered accounts: %s %v", raw, err)
	}

	// 0 uploaded.
	s := &outboxNegStore{outbox: eventstore.RelayWrapper{Store: outboxDB}, tombs: newTestTombs(t)}
	ch, err := s.QueryEvents(context.Background(), nostr.Filter{IDs: []string{strangerNote.ID, strangerFollows.ID, myNote.ID}})
	if err != nil {
		t.Fatal(err)
	}
	up := map[string]bool{}
	for ev := range ch {
		up[ev.ID] = true
	}
	if up[strangerNote.ID] || up[strangerFollows.ID] || !up[myNote.ID] {
		t.Fatalf("upload set = %v: want only my note", up)
	}

	// 0 on the public outbox: relay reads by id, by author, unfiltered, and counts.
	query := hideBroughtQuery(func(ctx context.Context, f nostr.Filter) (chan *nostr.Event, error) {
		return outboxDB.QueryEvents(ctx, f)
	})
	count := hideBroughtCount(func(ctx context.Context, f nostr.Filter) (int64, error) {
		return int64(countIn(t, outboxDB, f)), nil
	})
	served := func(ctx context.Context, f nostr.Filter) map[string]bool {
		ch, err := query(ctx, f)
		if err != nil {
			t.Fatal(err)
		}
		got := map[string]bool{}
		for ev := range ch {
			got[ev.ID] = true
		}
		return got
	}
	for _, f := range []nostr.Filter{theirs, {Authors: []string{stranger.pk}}, {Kinds: []int{1, 3}}} {
		if got := served(context.Background(), f); got[strangerNote.ID] || got[strangerFollows.ID] {
			t.Fatalf("filter %v served the stranger's events to a stranger: %v", f, got)
		}
		if n, _ := count(context.Background(), f); n != 0 && len(f.Authors) > 0 {
			t.Fatalf("count %v = %d, want 0", f, n)
		}
	}
	if n, _ := count(context.Background(), nostr.Filter{Kinds: []int{1}}); n != 1 {
		t.Fatalf("public kind-1 count = %d, want 1 (mine)", n)
	}
	if got := served(context.Background(), nostr.Filter{Kinds: []int{1}}); !got[myNote.ID] {
		t.Fatal("my own note is no longer served")
	}
	// Signed in with someone else's key: still a stranger.
	if got := served(authedAs(stranger.pk), theirs); len(got) != 0 {
		t.Fatalf("AUTH as the zip's own (not this vault's) account served %v", got)
	}
	// The vault's own reader still reads them.
	if got := served(authedAs(me.pk), theirs); len(got) != 2 {
		t.Fatalf("the owner's own read got %v, want both", got)
	}
	// The public page.
	for _, n := range fetchRecentNotes(context.Background(), 20) {
		if n.ID == strangerNote.ID {
			t.Fatal("the public page shows the stranger's note")
		}
	}
	// Mesh photos named only by the stranger's note.
	meshBlobs.reset()
	t.Cleanup(meshBlobs.reset)
	if meshBlobs.has(context.Background(), photo) {
		t.Fatal("the stranger's photo is served over the mesh")
	}

	// Signing in with that account later (AddAccountsC) makes it own: its
	// notes are here and it is normal from then on, served like any own
	// account's (Logen, 2026-11-06, after #1827; was read only for good).
	addLiveAccounts([]string{stranger.pk})
	if got := served(authedAs(stranger.pk), theirs); len(got) != 2 {
		t.Fatalf("after sign-in, its own read got %v, want both", got)
	}
	if got := served(context.Background(), theirs); len(got) != 2 {
		t.Fatalf("after sign-in, the public outbox served %v, want both", got)
	}
	meshBlobs.reset()
	if !meshBlobs.has(context.Background(), photo) {
		t.Fatal("after sign-in, its photo is not served over the mesh")
	}
}

// Positive control for the gate above: the owner's own zip (no stranger) is
// restored, uploaded and served as before.
func TestOwnZipStillUploadsAndServes(t *testing.T) {
	me := newTestKey(t)
	openCopyVault(t, me.pk)
	t.Cleanup(resetLiveAccounts)
	photo := strings.Repeat("cd", 32)
	myNote := me.sign(t, nostr.Event{Kind: 1, Content: "https://cdn.example/" + photo + ".jpg"})
	accounts := `{"v":1,"updated_at":1,"accounts":[{"npub":"` + npubOf(t, me.pk) + `"}]}`
	if err := importFromZip(context.Background(), writeAccountsZip(t, accounts, myNote)); err != nil {
		t.Fatal(err)
	}
	if len(broughtAccounts()) != 0 {
		t.Fatalf("own zip recorded brought accounts: %v", broughtAccounts())
	}
	s := &outboxNegStore{outbox: eventstore.RelayWrapper{Store: outboxDB}, tombs: newTestTombs(t)}
	ch, _ := s.QueryEvents(context.Background(), nostr.Filter{IDs: []string{myNote.ID}})
	n := 0
	for range ch {
		n++
	}
	if n != 1 {
		t.Fatal("own note not offered for upload")
	}
	query := hideBroughtQuery(func(ctx context.Context, f nostr.Filter) (chan *nostr.Event, error) {
		return outboxDB.QueryEvents(ctx, f)
	})
	ch, _ = query(context.Background(), nostr.Filter{IDs: []string{myNote.ID}})
	n = 0
	for range ch {
		n++
	}
	if n != 1 {
		t.Fatal("own note not served publicly")
	}
	meshBlobs.reset()
	t.Cleanup(meshBlobs.reset)
	if !meshBlobs.has(context.Background(), photo) {
		t.Fatal("own photo not served over the mesh")
	}
}

// A paired copy whose restore fails adds no account and offers nothing.
func TestCopyRestoreFailureTakesAccountsBack(t *testing.T) {
	me, them := newTestKey(t), newTestKey(t)
	openCopyVault(t, me.pk)
	t.Cleanup(resetLiveAccounts)
	shared := `{"v":1,"updated_at":1,"accounts":[{"npub":"` + npubOf(t, them.pk) + `"},{"npub":"` + npubOf(t, me.pk) + `"}]}`
	// Only a note nobody's store takes: nothing restored.
	bad := nostr.Event{Kind: 1, Content: "unsigned", PubKey: them.pk, ID: strings.Repeat("0", 64), Sig: strings.Repeat("0", 128)}
	var stats copyRestoreStats
	if _, _, err := restoreCopyNotes(context.Background(), writeAccountsZip(t, shared, bad), &stats); err == nil {
		t.Fatal("restore of nothing succeeded")
	}
	if isOwnKey(them.pk) {
		t.Fatal("a failed copy left its accounts own")
	}
	if _, err := os.Stat(copyAccountsFile); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("copy-accounts.json written by a failed copy: %v", err)
	}
}

// The copy: A (owner X, with L as an account) to B (owner L). B shares L, so
// it takes the copy and keeps X's notes (Tim's 22,412 skipped on 2026-11-06),
// but X is not added: it is offered, with its name, and becomes own only when
// the person ticks it (AddAccountsC), its notes already here.
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
	if isOwnKey(x.pk) {
		t.Fatal("the copy added X by itself; only the person may")
	}
	if countIn(t, outboxDB, nostr.Filter{IDs: []string{xNote.ID}}) != 1 {
		t.Fatal("X's note was skipped")
	}
	if countIn(t, outboxDB, nostr.Filter{IDs: []string{lNote.ID}}) != 1 {
		t.Fatal("L's note did not arrive")
	}
	raw, _ := os.ReadFile(copyAccountsFile)
	if !strings.Contains(string(raw), `"X"`) {
		t.Fatalf("B's app was not offered X with its name: %s", raw)
	}
	// The person ticks X later: its notes are already in the vault.
	addLiveAccounts([]string{x.pk})
	if !isOwnKey(x.pk) || countIn(t, outboxDB, nostr.Filter{Authors: []string{x.pk}}) != 1 {
		t.Fatal("adding X after the copy did not find its notes")
	}
}

// Catch-up: each side offers the other's accounts to its app and adds none;
// the offer only ever grows.
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
	if err != nil || got != "offered" {
		t.Fatalf("B's answer to A's accounts: %q %v", got, err)
	}
	if isOwnKey(a2.pk) {
		t.Fatal("the catch-up added A's account by itself")
	}
	if !isOwnKey(b2.pk) || !isOwnKey(me.pk) {
		t.Fatal("B lost an account it had")
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
	if why := takeCopyAccounts(put); why != "offered" {
		t.Fatalf("A's answer to B's accounts: %q", why)
	}
	if isOwnKey(b2.pk) || !isOwnKey(a2.pk) {
		t.Fatal("A added B's account by itself, or lost its own")
	}
	raw, _ = os.ReadFile(copyAccountsFile)
	if !strings.Contains(string(raw), `"A2"`) || !strings.Contains(string(raw), npubOf(t, b2.pk)) {
		t.Fatalf("A's app file: %s", raw)
	}
}

// A brought-over account is read from relays but never written to them
// (Logen, 2026-11-06; Tron #1807): the owner sync's upload source yields none
// of its events, lists included, while its new events still come down. An
// account that was already own when offered is not brought over, and the
// record never shrinks. Once the person ticks it (signs in here), it is own
// and normal again: its events upload (Logen, 2026-11-06, after #1827).
func TestBroughtOverAccountsAreNeverUploaded(t *testing.T) {
	owner, x, already := newTestKey(t), newTestKey(t), newTestKey(t)
	openCopyVault(t, owner.pk)
	t.Cleanup(resetLiveAccounts)
	addLiveAccounts([]string{already.pk})

	list := func(keys ...testKey) copyAccountList {
		var l copyAccountList
		l.V = 1
		for _, k := range keys {
			l.Accounts = append(l.Accounts, copyAccount{Npub: npubOf(t, k.pk)})
		}
		return l
	}
	offerCopyAccounts(list(owner, x, already))
	brought := broughtAccounts()
	if _, ok := brought[x.pk]; !ok || len(brought) != 1 {
		t.Fatalf("brought = %v, want only x", brought)
	}

	now := nostr.Now()
	ownerNote := owner.sign(t, nostr.Event{Kind: nostr.KindTextNote, CreatedAt: now, Content: "mine"})
	xNote := x.sign(t, nostr.Event{Kind: nostr.KindTextNote, CreatedAt: now, Content: "x"})
	xFollows := x.sign(t, nostr.Event{Kind: nostr.KindFollowList, CreatedAt: now})
	alreadyNote := already.sign(t, nostr.Event{Kind: nostr.KindTextNote, CreatedAt: now, Content: "own"})
	for _, ev := range []nostr.Event{ownerNote, xNote, xFollows, alreadyNote} {
		saveEv(t, outboxDB, ev)
	}
	s := &outboxNegStore{outbox: eventstore.RelayWrapper{Store: outboxDB}, tombs: newTestTombs(t)}
	ch, err := s.QueryEvents(context.Background(), nostr.Filter{IDs: []string{ownerNote.ID, xNote.ID, xFollows.ID, alreadyNote.ID}})
	if err != nil {
		t.Fatal(err)
	}
	up := map[string]bool{}
	for ev := range ch {
		up[ev.ID] = true
	}
	if up[xNote.ID] || up[xFollows.ID] {
		t.Fatal("a brought-over account's event would be uploaded")
	}
	if !up[ownerNote.ID] || !up[alreadyNote.ID] {
		t.Fatalf("own events not offered for upload: %v", up)
	}

	// The person ticks x (AddAccountsC); a later offer without x keeps it on
	// the record, but while own it is normal: its events upload.
	addLiveAccounts([]string{x.pk})
	offerCopyAccounts(list(owner))
	if !slices.Contains(readBroughtNpubs(), npubOf(t, x.pk)) {
		t.Fatal("ticking or a later offer took x off the brought-over record")
	}
	if _, b := broughtAccounts()[x.pk]; b {
		t.Fatal("x is still read only after signing in")
	}
	// Its note now; its list goes through the usual list rule like any own
	// account's (no relay to ask here, so not sent).
	ch, err = s.QueryEvents(context.Background(), nostr.Filter{IDs: []string{xNote.ID}})
	if err != nil {
		t.Fatal(err)
	}
	up = map[string]bool{}
	for ev := range ch {
		up[ev.ID] = true
	}
	if !up[xNote.ID] {
		t.Fatalf("after sign-in, x's note is not offered for upload: %v", up)
	}

	// Down still works for x.
	later := x.sign(t, nostr.Event{Kind: nostr.KindTextNote, CreatedAt: now + 1, Content: "x later"})
	if err := s.Publish(context.Background(), later); err != nil {
		t.Fatal(err)
	}
	if countIn(t, outboxDB, nostr.Filter{IDs: []string{later.ID}}) != 1 {
		t.Fatal("a brought-over account's new note did not come down")
	}
}

// writeStoresZip: a backup zip with accounts.json and the given stores.
func writeStoresZip(t *testing.T, accounts string, stores map[string][]nostr.Event) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "backup.zip")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	zw := zip.NewWriter(f)
	w, _ := zw.Create(copyAccountsEntry)
	_, _ = w.Write([]byte(accounts))
	for name, evs := range stores {
		w, _ := zw.Create(name + ".jsonl")
		for _, ev := range evs {
			line, _ := json.Marshal(ev)
			_, _ = w.Write(append(line, '\n'))
		}
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	_ = f.Close()
	return path
}

// The same stranger's zip, inbox and Blossom side (Tron #1808): events
// tagging the stranger are stored but not served from /inbox to anyone but
// the vault's own (one tagging the owner too stays visible), and the
// stranger's blob records are not restored, so /list/<stranger> stays empty.
func TestStrangerZipInboxAndBlobsAreNotServed(t *testing.T) {
	me, stranger, alice := newTestKey(t), newTestKey(t), newTestKey(t)
	openCopyVault(t, me.pk)
	t.Cleanup(resetLiveAccounts)
	now := nostr.Now()
	toStranger := alice.sign(t, nostr.Event{Kind: 1, CreatedAt: now, Content: "hi stranger", Tags: nostr.Tags{{"p", stranger.pk}}})
	toBoth := alice.sign(t, nostr.Event{Kind: 1, CreatedAt: now, Content: "hi both", Tags: nostr.Tags{{"p", stranger.pk}, {"p", me.pk}}})
	toMe := alice.sign(t, nostr.Event{Kind: 1, CreatedAt: now, Content: "hi me", Tags: nostr.Tags{{"p", me.pk}}})
	blob := func(uploader, x string) nostr.Event {
		ev := nostr.Event{PubKey: uploader, Kind: 24242, CreatedAt: now, Tags: nostr.Tags{{"x", x}, {"type", "image/jpeg"}, {"size", "12"}}}
		ev.ID = ev.GetID()
		return ev
	}
	strangerBlob, myBlob := blob(stranger.pk, strings.Repeat("ab", 32)), blob(me.pk, strings.Repeat("cd", 32))
	accounts := `{"v":1,"updated_at":1,"accounts":[{"npub":"` + npubOf(t, stranger.pk) + `"},{"npub":"` + npubOf(t, me.pk) + `"}]}`
	zipPath := writeStoresZip(t, accounts, map[string][]nostr.Event{
		"inbox":   {toStranger, toBoth, toMe},
		"blossom": {strangerBlob, myBlob},
	})
	if err := importFromZip(context.Background(), zipPath); err != nil {
		t.Fatalf("stranger zip naming the owner: %v", err)
	}

	// Inbox: all stored, the stranger-only one hidden from strangers.
	all := nostr.Filter{IDs: []string{toStranger.ID, toBoth.ID, toMe.ID}}
	if countIn(t, inboxDB, all) != 3 {
		t.Fatal("the zip's inbox events were not all stored")
	}
	query := hideBroughtInboxQuery(func(ctx context.Context, f nostr.Filter) (chan *nostr.Event, error) {
		return inboxDB.QueryEvents(ctx, f)
	})
	count := hideBroughtInboxCount(func(ctx context.Context, f nostr.Filter) (int64, error) {
		return int64(countIn(t, inboxDB, f)), nil
	})
	served := func(ctx context.Context, f nostr.Filter) map[string]bool {
		ch, err := query(ctx, f)
		if err != nil {
			t.Fatal(err)
		}
		got := map[string]bool{}
		for ev := range ch {
			got[ev.ID] = true
		}
		return got
	}
	for _, f := range []nostr.Filter{all, {Tags: nostr.TagMap{"p": []string{stranger.pk}}}, {Kinds: []int{1}}} {
		if got := served(context.Background(), f); got[toStranger.ID] {
			t.Fatalf("filter %v served the stranger's mail from /inbox: %v", f, got)
		}
	}
	if got := served(context.Background(), all); !got[toBoth.ID] || !got[toMe.ID] {
		t.Fatalf("mail to the owner is no longer served: %v", got)
	}
	if n, _ := count(context.Background(), nostr.Filter{Kinds: []int{1}, Tags: nostr.TagMap{"p": []string{stranger.pk}}}); n != 0 {
		t.Fatalf("count by the stranger's p tag = %d, want 0", n)
	}
	if n, _ := count(context.Background(), nostr.Filter{Kinds: []int{1}, Tags: nostr.TagMap{"p": []string{me.pk}}}); n != 2 {
		t.Fatalf("count by my p tag = %d, want 2", n)
	}
	if got := served(authedAs(stranger.pk), all); got[toStranger.ID] {
		t.Fatal("AUTH as the zip's (not this vault's) account was served its mail")
	}
	if got := served(authedAs(me.pk), all); len(got) != 3 {
		t.Fatalf("the owner's own read got %v, want all 3", got)
	}

	// Blossom: only my record restored.
	if countIn(t, blossomDB, nostr.Filter{Authors: []string{stranger.pk}, Kinds: []int{24242}}) != 0 {
		t.Fatal("the stranger's blob record was restored (listable at /list/<stranger>)")
	}
	if countIn(t, blossomDB, nostr.Filter{Authors: []string{me.pk}, Kinds: []int{24242}}) != 1 {
		t.Fatal("my own blob record was not restored")
	}
}

// Only the app's signing accounts travel (Tron, #1810): the owner, plus each
// own key copy-accounts.json lists. A look-only account (own, not in the
// file) and an offered one (in the file, never ticked) stay home. No file or
// a bad one: the owner only.
func TestLocalAccountsSendSigningAccountsOnly(t *testing.T) {
	owner, signing, lookOnly, offered := newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t)
	openCopyVault(t, owner.pk)
	t.Cleanup(resetLiveAccounts)
	addLiveAccounts([]string{signing.pk, lookOnly.pk})

	sent := func() map[string]string {
		var l copyAccountList
		if err := json.Unmarshal(marshalLocalCopyAccounts(), &l); err != nil {
			t.Fatal(err)
		}
		out := map[string]string{}
		for _, a := range l.Accounts {
			h, _ := npubHex(a.Npub)
			out[h] = a.Name
		}
		if len(l.Accounts) > 0 && l.Accounts[0].Npub != npubOf(t, owner.pk) {
			t.Fatalf("owner not first: %v", l.Accounts)
		}
		return out
	}

	_ = os.Remove(copyAccountsFile)
	if got := sent(); len(got) != 1 {
		t.Fatalf("no file: sent %v, want the owner only", got)
	}
	if _, ok := sent()[owner.pk]; !ok {
		t.Fatal("no file: the owner was not sent")
	}
	_ = os.WriteFile(copyAccountsFile, []byte(`{"v":1,"accounts":[{"npub":"`+signing.pk+`"}]}`), 0o600)
	if got := sent(); len(got) != 1 {
		t.Fatalf("refused file: sent %v, want the owner only", got)
	}

	app := `{"v":1,"updated_at":5,"accounts":[{"npub":"` + npubOf(t, signing.pk) + `","name":"Work"},{"npub":"` + npubOf(t, offered.pk) + `","name":"Offered"}]}`
	_ = os.WriteFile(copyAccountsFile, []byte(app), 0o600)
	got := sent()
	if _, ok := got[owner.pk]; !ok || got[signing.pk] != "Work" || len(got) != 2 {
		t.Fatalf("sent %v, want the owner and the signing account (named) only", got)
	}
	if _, ok := got[lookOnly.pk]; ok {
		t.Fatal("a look-only account travels")
	}
	if _, ok := got[offered.pk]; ok {
		t.Fatal("an offered, never-ticked account travels")
	}
}
