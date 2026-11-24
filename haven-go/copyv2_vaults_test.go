package main

// Desktop Vaults P10 (PLANS/NV_DESKTOP_VAULTS_PLAN.md §2.6): the Vault list in
// the settings copy merges per Vault id, and a copied Vault never pairs.

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr/nip19"
)

func TestCopyVaultsMergeFixtures(t *testing.T) {
	var fx struct {
		Now           int64
		TombstoneDays int `json:"tombstone_days"`
		Cases         []struct {
			Name                 string
			Mine, Theirs, Expect []any
		}
	}
	loadCopyFixture(t, "settings-vault-merge-cases.json", &fx)
	if fx.TombstoneDays != copyVaultTombDays {
		t.Fatalf("fixture keeps tombstones %d days, engine %d", fx.TombstoneDays, copyVaultTombDays)
	}
	if len(fx.Cases) < 10 {
		t.Fatalf("positive control: only %d merge cases", len(fx.Cases))
	}
	for _, c := range fx.Cases {
		got, _ := json.Marshal(copyVaultsMerge(c.Mine, c.Theirs, time.Unix(fx.Now, 0)))
		want, _ := json.Marshal(c.Expect)
		if !copySettingsSame(got, want) {
			t.Errorf("%s:\n got  %s\n want %s", c.Name, got, want)
		}
	}
}

func vaultFile(at int64, keys string) []byte {
	return []byte(`{"v":1,"updated_at":` + itoa(at) + `,"keys":{` + keys + `}}`)
}

func itoa(n int64) string { b, _ := json.Marshal(n); return string(b) }

// Whole-file newest wins for every other key; the Vault list merges from
// both sides even when that side's file lost.
func TestCopySettingsMergeKeepsBothSidesVaults(t *testing.T) {
	now := time.Unix(1767000300, 0)
	mine := vaultFile(100, `"zaps_only":true,"desktop_vaults":[{"id":"https:a.example","httpsURL":"https://a.example","order":0,"updatedAt":150}]`)
	theirs := vaultFile(200, `"zaps_only":false,"desktop_vaults":[{"id":"https:b.example","httpsURL":"https://b.example","order":1,"updatedAt":120}]`)
	merged, err := copySettingsMerge(mine, theirs, now)
	if err != nil || copySettingsRefusal(merged, now) != "" {
		t.Fatalf("merge: %v %q", err, copySettingsRefusal(merged, now))
	}
	var out struct {
		UpdatedAt int64 `json:"updated_at"`
		Keys      struct {
			ZapsOnly bool `json:"zaps_only"`
			Vaults   []struct {
				ID string `json:"id"`
			} `json:"desktop_vaults"`
		}
	}
	_ = json.Unmarshal(merged, &out)
	if out.UpdatedAt != 200 || out.Keys.ZapsOnly {
		t.Fatalf("newer file's keys lost: %s", merged)
	}
	if len(out.Keys.Vaults) != 2 || out.Keys.Vaults[0].ID != "https:a.example" || out.Keys.Vaults[1].ID != "https:b.example" {
		t.Fatalf("a Vault from one side was dropped: %s", merged)
	}
	// The older side has no Vault list at all: the newer side's still stands.
	merged, _ = copySettingsMerge(vaultFile(300, `"zaps_only":true`), theirs, now)
	if !strings.Contains(string(merged), "https:b.example") || !strings.Contains(string(merged), `"zaps_only":true`) {
		t.Fatalf("Vault list dropped by a newer file without one: %s", merged)
	}
	// Neither side has one: none is added.
	merged, _ = copySettingsMerge(vaultFile(1, `"zaps_only":true`), vaultFile(2, `"zaps_only":false`), now)
	if strings.Contains(string(merged), "desktop_vaults") {
		t.Fatalf("an empty Vault list was invented: %s", merged)
	}
}

// storeCopySettings, the one way in from another device, merges: a Vault
// added here survives a newer file from a device that never had it.
func TestStoreCopySettingsMergesVaults(t *testing.T) {
	t.Chdir(t.TempDir())
	now := time.Now().Unix()
	_ = os.WriteFile(copySettingsFile, vaultFile(now-100, `"desktop_vaults":[{"id":"https:here.example","httpsURL":"https://here.example","order":0,"updatedAt":`+itoa(now-100)+`}]`), 0o600)
	theirs := vaultFile(now-10, `"desktop_vaults":[{"id":"https:there.example","httpsURL":"https://there.example","order":1,"updatedAt":`+itoa(now-50)+`}]`)
	if got := storeCopySettings(theirs); got != "included" {
		t.Fatalf("store: %q", got)
	}
	raw, _ := os.ReadFile(copySettingsFile)
	if !strings.Contains(string(raw), "here.example") || !strings.Contains(string(raw), "there.example") {
		t.Fatalf("not merged: %s", raw)
	}
	// Mutation guard: a whole-file write would have lost "here".
	if copySettingsSame(raw, theirs) {
		t.Fatal("stored theirs whole")
	}
	// A tombstone from there, newer than the Vault here, removes it.
	_ = storeCopySettings(vaultFile(now-5, `"desktop_vaults":[{"id":"https:here.example","deletedAt":`+itoa(now-5)+`}]`))
	raw, _ = os.ReadFile(copySettingsFile)
	if strings.Contains(string(raw), "https://here.example") || !strings.Contains(string(raw), "there.example") {
		t.Fatalf("tombstone not applied per Vault: %s", raw)
	}
	// A refused file changes nothing.
	before := raw
	if got := storeCopySettings(vaultFile(now, `"desktop_vaults":[{"id":"x","httpsURL":"https://x.example","order":0,"updatedAt":1,"paired":true}]`)); got != "refused" {
		t.Fatalf("a Vault with an unlisted field: %q, want refused", got)
	}
	raw, _ = os.ReadFile(copySettingsFile)
	if string(raw) != string(before) {
		t.Fatal("a refused file was written")
	}
}

// A copied Vault grants nothing (§2.6): taking in a Vault list that names a
// mesh npub never adds it to the paired set, so it gets no copy v2 trust.
func TestCopiedVaultNeverGrantsPairing(t *testing.T) {
	t.Chdir(t.TempDir())
	vault, phone, stranger := newTestKey(t), newTestKey(t), newTestKey(t)
	prev := meshDevices
	meshDevices = &meshDeviceSet{devices: map[string]string{}, seen: map[string]int64{}, now: time.Now}
	t.Cleanup(func() { meshDevices = prev })
	if err := meshDevices.set(meshSetJSON(t, vault, phone)); err != nil {
		t.Fatal(err)
	}
	before := meshDevices.pairedKeys()

	npub, _ := nip19.EncodePublicKey(stranger.pk)
	now := time.Now().Unix()
	file := vaultFile(now, `"desktop_vaults":[{"id":"mesh:`+npub+`","name":"Stranger","meshNpub":"`+npub+`","order":0,"updatedAt":`+itoa(now)+`}]`)
	if got := storeCopySettings(file); got != "included" {
		t.Fatalf("store: %q", got)
	}
	raw, _ := os.ReadFile(copySettingsFile)
	if !strings.Contains(string(raw), npub) {
		t.Fatal("positive control: the Vault list was not taken in")
	}
	if meshDevices.paired(stranger.pk) {
		t.Fatal("a copied Vault paired its mesh npub")
	}
	if after := meshDevices.pairedKeys(); len(after) != len(before) {
		t.Fatalf("paired set changed: %v -> %v", before, after)
	}
}
