//go:build cshared

package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/barrydeen/haven/pkg/wot"
	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip19"
)

// The WOT tab's rebuild with the vault on Citrine: the embedded relay is not
// running, and the web is built from the follow list Citrine holds into the
// wot_cache.json the apps read. RefreshWotC said "relay isn't running".
func TestRefreshWotFromRelayBuildsFromTheOutsideRelaysFollowList(t *testing.T) {
	if relayLC.current.Load() != nil {
		t.Skip("a relay is running in this process")
	}
	dir := t.TempDir()
	sk, pk := newKey(t)
	_, friend := newKey(t)
	npub, _ := nip19.EncodePublicKey(pk)
	url := citrineRelay(t, signedFollowList(t, sk, nostr.Now(), friend))
	empty := filepath.Join(dir, "none.json")
	if err := os.WriteFile(empty, []byte("[]"), 0o644); err != nil {
		t.Fatal(err)
	}
	cache := filepath.Join(dir, "wot_cache.json")
	wd, _ := os.Getwd()
	t.Cleanup(func() { os.Chdir(wd) })
	saved := config
	t.Cleanup(func() { config = saved })
	for k, v := range map[string]string{
		"DATABASE_PATH":             filepath.Join(dir, "db") + "/",
		"OWNER_NPUB":                npub,
		"IMPORT_SEED_RELAYS_FILE":   empty,
		"BLASTR_RELAYS_FILE":        empty,
		"DM_RELAYS_FILE":            empty,
		"WOT_DEPTH":                 "2",
		"WOT_FETCH_TIMEOUT_SECONDS": "5",
		"WOT_CACHE_PATH":            cache,
	} {
		t.Setenv(k, v)
	}

	if !startExternalWotRefresh(url) {
		t.Fatal("the rebuild did not start")
	}
	deadline := time.Now().Add(10 * time.Second)
	for wot.CurrentProgress().Running && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if p := wot.CurrentProgress(); p.Running || p.Phase != "saved" {
		t.Fatalf("rebuild did not save: %+v", p)
	}
	raw, err := os.ReadFile(cache)
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		Pubkeys map[string]bool `json:"pubkeys"`
		Follows []string        `json:"follows"`
	}
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatal(err)
	}
	if !got.Pubkeys[friend] || !slices.Contains(got.Follows, friend) {
		t.Fatalf("the web is missing the follow from Citrine's list: %s", raw)
	}
}

// With our own relay up, the tab uses RefreshWotC; this one stays out of it.
func TestRefreshWotFromRelayNeedsTheRelayEnv(t *testing.T) {
	t.Setenv("DATABASE_PATH", "")
	if startExternalWotRefresh("ws://127.0.0.1:1") {
		t.Fatal("started without a data directory")
	}
}
