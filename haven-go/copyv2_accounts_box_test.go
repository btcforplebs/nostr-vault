package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/barrydeen/haven/internal/box"
)

// A box offers another device, in a copy, its first account and its
// signed-in accounts, never a watch-only one (One Vault addendum A, E11).
// The box writes copy-accounts.json (internal/box copy_accounts.go); this
// checks the engine reads what the box writes the way it reads the Mac
// app's file. Without the file, a box offered the first account alone.
func TestBoxOffersFirstAndSignedInAccounts(t *testing.T) {
	owner, signed, watch := newTestKey(t), newTestKey(t), newTestKey(t)
	openCopyVault(t, owner.pk)
	// The box's engine whitelist: every account it holds.
	config.WhitelistedPubKeys = map[string]struct{}{owner.pk: {}, signed.pk: {}, watch.pk: {}}

	sent := func() map[string]string {
		t.Helper()
		var l copyAccountList
		if err := json.Unmarshal(marshalLocalCopyAccounts(), &l); err != nil {
			t.Fatal(err)
		}
		out := map[string]string{}
		for _, a := range l.Accounts {
			h, _ := npubHex(a.Npub)
			out[h] = a.Name
		}
		return out
	}

	// Before E11: no file on a box, the first account alone.
	_ = os.Remove(copyAccountsFile)
	if got := sent(); len(got) != 1 {
		t.Fatalf("no file: sent %v, want the first account only", got)
	}

	data := t.TempDir()
	cfg := box.Config{DataDir: data, OwnerHex: owner.pk, OwnerNpub: npubOf(t, owner.pk)}
	if err := box.SaveAccounts(cfg.AccountsFile(), []box.Account{
		{Npub: npubOf(t, watch.pk), Name: "Mirror"},
		{Npub: npubOf(t, signed.pk), SignedIn: true, Name: "Work"},
	}); err != nil {
		t.Fatal(err)
	}
	vault := filepath.Join(data, "vault")
	if err := box.WriteEngineFiles(cfg, vault); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(vault, copyAccountsFile))
	if err != nil {
		t.Fatalf("the box wrote no %s: %v", copyAccountsFile, err)
	}
	if _, why := copyAccountsRefusal(raw); why != "" {
		t.Fatalf("the engine refuses the box's file: %s\n%s", why, raw)
	}
	if err := os.WriteFile(copyAccountsFile, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	got := sent()
	if _, ok := got[owner.pk]; !ok || got[signed.pk] != "Work" || len(got) != 2 {
		t.Fatalf("sent %v, want the first account and the signed-in one (named)", got)
	}
	if _, ok := got[watch.pk]; ok {
		t.Fatal("a watch-only account is offered")
	}
}
