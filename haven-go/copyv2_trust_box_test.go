//go:build !cshared && !(js && wasm)

package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/barrydeen/haven/internal/box"
)

// Desktop Vaults P12 (Logen 2026-11-24 15:31Z, "boxes can serve WoT
// rankings over mesh to phone, yes"): a box is a Haven like a Mac. Its
// command-line engine ranks the accounts havend writes into
// copy-accounts.json and hands each result over GET /copy/v2/sync/trust to
// the devices in the paired set havend writes (P9,
// internal/box/devices_engine.go), and to nobody once one is removed.
func TestBoxHandsItsTrustRankToThePairedSetOnly(t *testing.T) {
	owner, signed, watch := newTestKey(t), newTestKey(t), newTestKey(t)
	vaultKey, phone := newTestKey(t), newTestKey(t)
	openCopyVault(t, owner.pk)
	config.WhitelistedPubKeys = map[string]struct{}{owner.pk: {}, signed.pk: {}, watch.pk: {}}

	// A box ranks: no app flag is needed, and only TRUST_RANK=off stops it.
	if !trustRankWanted("linux", "") || trustRankWanted("linux", "off") {
		t.Fatal("a box must rank by default and stop on TRUST_RANK=off")
	}
	if !trustRankMayRun(false, false, false, time.Time{}, time.Now()) {
		t.Fatal("the command-line engine must not wait for an app's background flag")
	}

	// havend's account file, written into the engine's working folder.
	vault, _ := os.Getwd()
	data := t.TempDir()
	cfg := box.Config{DataDir: data, OwnerHex: owner.pk, OwnerNpub: npubOf(t, owner.pk)}
	if err := box.SaveAccounts(cfg.AccountsFile(), []box.Account{
		{Npub: npubOf(t, watch.pk), Name: "Mirror"},
		{Npub: npubOf(t, signed.pk), SignedIn: true, Name: "Work"},
	}); err != nil {
		t.Fatal(err)
	}
	if err := box.WriteEngineFiles(cfg, vault); err != nil {
		t.Fatal(err)
	}

	// havend's paired-set file, written by havend's own writer (P9
	// EngineDevices.Sync) from nv-mesh's npub and mesh-devices.json, and
	// read the way the engine reads it.
	pairMeshDevices(t, vaultKey) // a fresh set, restored after the test
	meshDir := t.TempDir()
	npubFile := filepath.Join(meshDir, "npub")
	if err := os.WriteFile(npubFile, []byte(npubOf(t, vaultKey.pk)+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	meshList := filepath.Join(meshDir, "mesh-devices.json")
	writeList := func(keys ...testKey) {
		t.Helper()
		body := "["
		for i, k := range keys {
			if i > 0 {
				body += ","
			}
			body += `{"npub":"` + npubOf(t, k.pk) + `"}`
		}
		if err := os.WriteFile(meshList, []byte(body+"]\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	devices := filepath.Join(t.TempDir(), "engine-mesh-devices.json")
	writer := &box.EngineDevices{Mesh: box.MeshID{NpubFile: npubFile}, From: meshList, To: devices}
	writeList(vaultKey, phone) // nv-mesh's list names the box too; havend drops it
	if changed, err := writer.Sync(); err != nil || !changed {
		t.Fatalf("havend did not write the paired set: changed %v, %v", changed, err)
	}
	(&meshDevicesFile{path: devices}).load()
	if !meshDevices.paired(phone.pk) {
		t.Fatal("the paired-set file was not applied")
	}

	_, s := copySyncPair(t, owner)
	token := copyPeerToken("npub1peer")
	s.tokens[0].Device = phone.pk
	ts := httptest.NewServer(s)
	t.Cleanup(ts.Close)
	aDir := t.TempDir()
	config.WotCachePath = filepath.Join(aDir, "wot_cache.json")
	for _, a := range []string{owner.pk, signed.pk, watch.pk} {
		writeTrustFile(t, aDir, a, 100)
	}

	// The first and the signed-in account travel; a watch-only one is not
	// the owner's and does not.
	for _, c := range []struct {
		name, account string
		want          int
	}{{"first account", owner.pk, http.StatusOK}, {"signed-in account", signed.pk, http.StatusOK}, {"watch-only account", watch.pk, http.StatusNotFound}} {
		if resp := trustGet(t, ts.URL, "?account="+c.account, token); resp.StatusCode != c.want {
			t.Fatalf("%s: %d, want %d", c.name, resp.StatusCode, c.want)
		}
	}

	// Remove in the box UI rewrites the file without the phone: its token
	// is refused at once, and still after an engine restart.
	writeList(vaultKey)
	if changed, err := writer.Sync(); err != nil || !changed {
		t.Fatalf("havend did not rewrite the paired set: changed %v, %v", changed, err)
	}
	(&meshDevicesFile{path: devices}).load()
	if resp := trustGet(t, ts.URL, "?account="+owner.pk, token); resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("a removed device got the rank: %d", resp.StatusCode)
	}
	pairMeshDevices(t, newTestKey(t)) // the restart: an empty set again
	(&meshDevicesFile{path: devices}).load()
	if resp := trustGet(t, ts.URL, "?account="+owner.pk, token); resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("a removed device got the rank after a restart: %d", resp.StatusCode)
	}
}
