package box

import (
	"os"
	"path/filepath"
	"testing"
)

// The Trust ranking card's data: the engine's file as it is, null before
// one exists, an error for a broken one, and only for signed-in accounts.
func TestVaultStatusServesTheEnginesFile(t *testing.T) {
	srv, owner, member, api := signedInAPI(t)
	if st, out := call(t, srv, &member, "GET", "/api/box/vault-status", nil); st != 200 || out["status"] != nil {
		t.Fatalf("no file yet: %d %v", st, out)
	}
	path := filepath.Join(api.Mover.Engine.VaultDir(), vaultStatusFile)
	os.WriteFile(path, []byte(`{"version":1,"at":5,"state":"running","accounts":[{"account":"ab","running":true,"ring":3,"handoffs":[]}]}`), 0o600)
	st, out := call(t, srv, &owner, "GET", "/api/box/vault-status", nil)
	status, _ := out["status"].(map[string]any)
	if st != 200 || status["state"] != "running" || len(status["accounts"].([]any)) != 1 || out["writtenAt"].(float64) <= 0 {
		t.Fatalf("status: %d %v", st, out)
	}
	// A second same-second call by one key is a replay (the NIP-98 id repeats): another member asks.
	other := newTestKey(t)
	if _, err := api.Accounts.Join(other.pk, "Other"); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(path, []byte(`{"version":1,`), 0o600)
	if st, _ := call(t, srv, &other, "GET", "/api/box/vault-status", nil); st != 500 {
		t.Fatalf("a cut file: %d", st)
	}
	stranger := newTestKey(t)
	if st, _ := call(t, srv, &stranger, "GET", "/api/box/vault-status", nil); st == 200 {
		t.Fatalf("a key the box does not hold read it")
	}
}
