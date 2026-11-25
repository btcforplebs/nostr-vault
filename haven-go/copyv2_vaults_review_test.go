package main

// Desktop Vaults P10, Tron's review of #2521: an empty Vault list is left out
// (older engines refuse the key), a merge never makes a file past the cap,
// and two writers of the settings file never lose each other's merge.

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func vaultEntriesJSON(prefix string, n int, at int64) string {
	var parts []string
	for i := 0; i < n; i++ {
		parts = append(parts, fmt.Sprintf(`{"id":"https:%s%02d.example","httpsURL":"https://%s%02d.example","order":%d,"updatedAt":%d}`,
			prefix, i, prefix, i, i, at))
	}
	return `"desktop_vaults":[` + strings.Join(parts, ",") + `]`
}

// A pre-P10 engine has no desktop_vaults in its allowlist and refuses the
// whole file as unknown_key, so the merge never writes an empty list.
func TestCopySettingsMergeLeavesEmptyVaultsOut(t *testing.T) {
	now := time.Unix(1767000300, 0)
	for name, pair := range map[string][2][]byte{
		"neither has the key": {vaultFile(100, `"zaps_only":true`), vaultFile(200, `"zaps_only":false`)},
		"both empty":          {vaultFile(100, `"desktop_vaults":[]`), vaultFile(200, `"desktop_vaults":[]`)},
		"winner empty":        {vaultFile(100, `"zaps_only":true`), vaultFile(200, `"desktop_vaults":[]`)},
	} {
		merged, err := copySettingsMerge(pair[0], pair[1], now)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if strings.Contains(string(merged), "desktop_vaults") {
			t.Fatalf("%s: empty list written: %s", name, merged)
		}
	}
	// A list with entries is still written.
	merged, _ := copySettingsMerge(vaultFile(100, vaultEntriesJSON("a", 1, 100)), vaultFile(200, `"zaps_only":false`), now)
	if !strings.Contains(string(merged), "a00.example") {
		t.Fatalf("a real list was dropped: %s", merged)
	}
}

// Two lists of 20 that each pass merge to 40; the stored file keeps the first
// 32 by (order, id) and is not refused, so settings sync between the two
// devices goes on.
func TestStoreCopySettingsCapsMergedVaults(t *testing.T) {
	t.Chdir(t.TempDir())
	now := time.Now().Unix()
	_ = os.WriteFile(copySettingsFile, vaultFile(now-100, vaultEntriesJSON("m", 20, now-100)), 0o600)
	if got := storeCopySettings(vaultFile(now-10, vaultEntriesJSON("t", 20, now-10))); got != "included" {
		t.Fatalf("store: %q, want included", got)
	}
	raw, _ := os.ReadFile(copySettingsFile)
	if why := copySettingsRefusal(raw, time.Now()); why != "" {
		t.Fatalf("stored file refused: %s", why)
	}
	var f struct {
		Keys struct {
			Vaults []map[string]any `json:"desktop_vaults"`
		} `json:"keys"`
	}
	_ = json.Unmarshal(raw, &f)
	if len(f.Keys.Vaults) != copyVaultsMax {
		t.Fatalf("%d Vaults, want %d", len(f.Keys.Vaults), copyVaultsMax)
	}
	// Orders 0..15 from both sides (32 entries); order 16 and up is left out.
	for _, v := range f.Keys.Vaults {
		if v["order"].(float64) >= 16 {
			t.Fatalf("kept %v past the cap", v["id"])
		}
	}
}

// An incoming PUT and this device's own catch-up store at once: every merge
// lands, and no temp file is left behind.
func TestStoreCopySettingsConcurrentWritersKeepEveryVault(t *testing.T) {
	dir := t.TempDir()
	t.Chdir(dir)
	now := time.Now().Unix()
	const n = 24
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			storeCopySettings(vaultFile(now-int64(n-i), fmt.Sprintf(`"desktop_vaults":[{"id":"https:w%02d.example","httpsURL":"https://w%02d.example","order":%d,"updatedAt":%d}]`, i, i, i, now-int64(n-i))))
		}(i)
	}
	wg.Wait()
	raw, _ := os.ReadFile(copySettingsFile)
	for i := 0; i < n; i++ {
		if !strings.Contains(string(raw), fmt.Sprintf("w%02d.example", i)) {
			t.Fatalf("writer %d's Vault was lost: %s", i, raw)
		}
	}
	if left, _ := filepath.Glob(filepath.Join(dir, "*.tmp")); len(left) > 0 {
		t.Fatalf("temp files left: %v", left)
	}
}
