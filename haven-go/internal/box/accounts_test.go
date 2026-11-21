package box

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip19"
)

func testNpub(t *testing.T) (hexKey, npub string) {
	t.Helper()
	k := newTestKey(t)
	n, err := nip19.EncodePublicKey(k.pk)
	if err != nil {
		t.Fatal(err)
	}
	return k.pk, n
}

func TestListsForNamesReadersApart(t *testing.T) {
	_, owner := testNpub(t)
	_, watch := testNpub(t)
	_, signed := testNpub(t)
	l := ListsFor(owner, []Account{
		{Npub: watch},
		{Npub: signed, SignedIn: true},
		{Npub: owner}, // the first account again: counts once, stays a reader
		{Npub: watch}, // a repeat, still watch-only
	})
	if want := []string{owner, watch, signed}; !slices.Equal(l.Accounts, want) {
		t.Fatalf("Accounts = %v, want %v", l.Accounts, want)
	}
	if want := []string{owner, signed}; !slices.Equal(l.Readers, want) {
		t.Fatalf("Readers = %v, want %v (a watch-only account must never read)", l.Readers, want)
	}
	if l := ListsFor(owner, nil); !slices.Equal(l.Accounts, []string{owner}) || !slices.Equal(l.Readers, []string{owner}) {
		t.Fatalf("no added accounts: %+v, want the first account alone", l)
	}
}

func TestLoadAccountsFailsClosed(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "accounts.json")
	if got := LoadAccounts(path); got != nil {
		t.Fatalf("missing file = %v, want none", got)
	}
	os.WriteFile(path, []byte("{not json"), 0o600)
	if got := LoadAccounts(path); got != nil {
		t.Fatalf("corrupt file = %v, want none", got)
	}

	hexKey, npub := testNpub(t)
	nsec, _ := nip19.EncodePrivateKey(nostr.GeneratePrivateKey())
	raw, _ := json.Marshal([]Account{
		{Npub: strings.ToUpper(hexKey), SignedIn: true, Name: "hex"},
		{Npub: nsec, SignedIn: true},
		{Npub: "npub1notakey"},
		{Npub: ""},
	})
	os.WriteFile(path, raw, 0o600)
	got := LoadAccounts(path)
	if len(got) != 1 || got[0].Npub != npub || !got[0].SignedIn || got[0].Name != "hex" {
		t.Fatalf("LoadAccounts = %+v, want only the hex entry, as its npub", got)
	}
}

func TestSaveAccountsRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "box", "accounts.json")
	_, npub := testNpub(t)
	in := []Account{{Npub: npub, Added: 1700000000, SignedIn: true, Name: "work"}}
	if err := SaveAccounts(path, in); err != nil {
		t.Fatal(err)
	}
	if fi, err := os.Stat(path); err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("stat %v %v, want 0600", fi, err)
	}
	if got := LoadAccounts(path); !slices.Equal(got, in) {
		t.Fatalf("round trip = %+v, want %+v", got, in)
	}
	if err := SaveAccounts(path, nil); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(path); strings.TrimSpace(string(b)) != "[]" {
		t.Fatalf("empty save = %q, want []", b)
	}
	if left, _ := filepath.Glob(filepath.Join(filepath.Dir(path), ".accounts-*")); len(left) != 0 {
		t.Fatalf("temp files left: %v", left)
	}
}

func readList(t *testing.T, path string) []string {
	t.Helper()
	var l []string
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(b, &l); err != nil {
		t.Fatal(err)
	}
	return l
}

func TestWriteEngineFilesWritesBothLists(t *testing.T) {
	ownerHex, owner := testNpub(t)
	_, watch := testNpub(t)
	_, signed := testNpub(t)
	c := Config{DataDir: t.TempDir(), OwnerHex: ownerHex, OwnerNpub: owner}
	vault := c.DefaultVaultDir()

	// The readers file is named in the environment, always.
	env := EngineEnv(c, vault)
	if env["PRIVATE_READER_NPUBS_FILE"] != "private_reader_npubs.json" {
		t.Fatalf("PRIVATE_READER_NPUBS_FILE = %q: unnamed, the engine lets every account read", env["PRIVATE_READER_NPUBS_FILE"])
	}

	// No accounts.json: exactly the box from before accounts.
	if err := WriteEngineFiles(c, vault); err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{"whitelisted_npubs.json", "private_reader_npubs.json"} {
		if got := readList(t, filepath.Join(vault, f)); !slices.Equal(got, []string{owner}) {
			t.Fatalf("%s = %v, want the first account alone", f, got)
		}
	}

	if err := SaveAccounts(c.AccountsFile(), []Account{{Npub: watch}, {Npub: signed, SignedIn: true}}); err != nil {
		t.Fatal(err)
	}
	if err := WriteEngineFiles(c, vault); err != nil {
		t.Fatal(err)
	}
	if got := readList(t, filepath.Join(vault, "whitelisted_npubs.json")); !slices.Equal(got, []string{owner, watch, signed}) {
		t.Fatalf("whitelist = %v", got)
	}
	if got := readList(t, filepath.Join(vault, "private_reader_npubs.json")); !slices.Equal(got, []string{owner, signed}) {
		t.Fatalf("readers = %v", got)
	}

	// Removed: both lists shrink on the next start.
	if err := SaveAccounts(c.AccountsFile(), nil); err != nil {
		t.Fatal(err)
	}
	if err := WriteEngineFiles(c, vault); err != nil {
		t.Fatal(err)
	}
	if got := readList(t, filepath.Join(vault, "whitelisted_npubs.json")); !slices.Equal(got, []string{owner}) {
		t.Fatalf("whitelist after removal = %v", got)
	}
}

type fakeReloader struct{ n int }

func (f *fakeReloader) Reload() bool { f.n++; return true }

func TestAccountsWatchReloadsOnlyOnChange(t *testing.T) {
	ownerHex, owner := testNpub(t)
	_, other := testNpub(t)
	c := Config{DataDir: t.TempDir(), OwnerHex: ownerHex, OwnerNpub: owner}
	r := &fakeReloader{}
	w := &AccountsWatch{Config: c, Engine: r}

	if w.Check() || r.n != 0 {
		t.Fatal("the first check must only record the lists the engine started with")
	}
	if w.Check() || r.n != 0 {
		t.Fatal("reloaded with nothing changed")
	}
	SaveAccounts(c.AccountsFile(), []Account{{Npub: other}})
	if !w.Check() || r.n != 1 {
		t.Fatalf("added account: reloads = %d, want 1", r.n)
	}
	// A name change alone does not touch the engine's lists.
	SaveAccounts(c.AccountsFile(), []Account{{Npub: other, Name: "renamed"}})
	if w.Check() || r.n != 1 {
		t.Fatalf("rename reloaded the engine: %d", r.n)
	}
	SaveAccounts(c.AccountsFile(), []Account{{Npub: other, SignedIn: true}})
	if !w.Check() || r.n != 2 {
		t.Fatalf("signed in: reloads = %d, want 2", r.n)
	}
	SaveAccounts(c.AccountsFile(), nil)
	if !w.Check() || r.n != 3 {
		t.Fatalf("removed: reloads = %d, want 3", r.n)
	}
}

// Tron #2374: a change made after Seed (havend seeds before the engine
// starts) but before the first Check must reload, not become the baseline.
func TestAccountsWatchSeedCatchesAChangeBeforeTheFirstCheck(t *testing.T) {
	ownerHex, owner := testNpub(t)
	_, other := testNpub(t)
	c := Config{DataDir: t.TempDir(), OwnerHex: ownerHex, OwnerNpub: owner}
	r := &fakeReloader{}
	w := &AccountsWatch{Config: c, Engine: r}
	w.Seed()
	SaveAccounts(c.AccountsFile(), []Account{{Npub: other, SignedIn: true}})
	if !w.Check() || r.n != 1 {
		t.Fatalf("a join before the first Check: reloads = %d, want 1", r.n)
	}
}
