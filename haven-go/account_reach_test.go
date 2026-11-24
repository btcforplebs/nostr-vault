package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip19"

	"github.com/barrydeen/haven/pkg/wot"
)

func reachTestAccount(t *testing.T) (npub, hex string) {
	t.Helper()
	hex, err := nostr.GetPublicKey(nostr.GeneratePrivateKey())
	if err != nil {
		t.Fatal(err)
	}
	npub, err = nip19.EncodePublicKey(hex)
	if err != nil {
		t.Fatal(err)
	}
	return npub, hex
}

// The file gives each account its own level and bar, keyed by npub. Values
// outside the range are pulled in, a bad key is skipped, and an account with
// no entry has none (it then uses the vault's single value).
func TestAccountReachFileIsReadPerAccount(t *testing.T) {
	npubA, hexA := reachTestAccount(t)
	npubB, hexB := reachTestAccount(t)
	npubC, hexC := reachTestAccount(t)
	_, hexNone := reachTestAccount(t)
	path := filepath.Join(t.TempDir(), "account_reach.json")
	body := `{"v":1,"accounts":{
		"` + npubA + `":{"depth":2,"min_followers":5},
		"` + npubB + `":{"depth":0,"min_followers":-4},
		"` + npubC + `":{"depth":9},
		"not-an-npub":{"depth":1},
		"` + hexA + `":{"depth":1}}}`
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	got := loadAccountReach(path)
	want := reachByAccount{
		hexA: {Depth: 2, MinFollowers: 5},
		hexB: {Depth: 1, MinFollowers: 0}, // level 0 is only ever WOT_DEPTH=0
		hexC: {Depth: 3, MinFollowers: 0},
	}
	if len(got) != len(want) {
		t.Fatalf("read %d entries, want %d: %v", len(got), len(want), got)
	}
	for pk, reach := range want {
		if got[pk] != reach {
			t.Errorf("entry %s = %+v, want %+v", pk[:8], got[pk], reach)
		}
	}

	saved := config.AccountReach
	t.Cleanup(func() { config.AccountReach = saved })
	config.AccountReach = got
	if reach, ok := accountReach(hexA); !ok || reach != (wot.AccountReach{Depth: 2, MinFollowers: 5}) {
		t.Errorf("accountReach(A) = %+v, %v", reach, ok)
	}
	if _, ok := accountReach(hexNone); ok {
		t.Error("an account with no entry must report none, so it uses the vault's value")
	}
}

// No file, a broken file, or a version this build does not know: no account
// gets an entry, and the relay runs on the single value as before.
func TestAccountReachFileMissingOrUnknownMeansNoEntries(t *testing.T) {
	npub, _ := reachTestAccount(t)
	dir := t.TempDir()
	cases := map[string]string{
		"broken.json":  `{"v":1,"accounts":`,
		"version.json": `{"v":2,"accounts":{"` + npub + `":{"depth":1}}}`,
		"list.json":    `["` + npub + `"]`,
	}
	for name, body := range cases {
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		if got := loadAccountReach(path); len(got) != 0 {
			t.Errorf("%s: read %v, want no entries", name, got)
		}
	}
	if got := loadAccountReach(filepath.Join(dir, "absent.json")); len(got) != 0 {
		t.Errorf("a missing file gave %v", got)
	}
	if got := loadAccountReach(""); len(got) != 0 {
		t.Errorf("no path gave %v", got)
	}
}
