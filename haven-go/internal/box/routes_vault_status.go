package box

// The desktop Vault status on a box (step 4 of the status work): what the
// engine's trust ranking, distant posts and rank hand-off are doing, for the
// Vault Dashboard's Trust ranking card. The engine writes it to
// vault_status.json in the vault folder every 15 s (haven-go
// vault_status_file.go); the box hands it over as it is, with when it was
// written, so the card can say how old it is.
//
//	GET /api/box/vault-status  -> {status: {...} | null, writtenAt}  signed in

import (
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
)

const vaultStatusFile = "vault_status.json"

func init() {
	handle("GET /api/box/vault-status", SignedIn, func(a *API, w http.ResponseWriter, _ *http.Request, _ Caller, _ []byte) {
		path := filepath.Join(a.Mover.Engine.VaultDir(), vaultStatusFile)
		raw, err := os.ReadFile(path)
		if errors.Is(err, os.ErrNotExist) {
			// An engine from before this, or one that has not written yet.
			writeJSON(w, http.StatusOK, map[string]any{"status": nil})
			return
		}
		var st map[string]any
		if err != nil || json.Unmarshal(raw, &st) != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "the vault's status file can't be read"})
			return
		}
		var written int64
		if fi, err := os.Stat(path); err == nil {
			written = fi.ModTime().Unix()
		}
		writeJSON(w, http.StatusOK, map[string]any{"status": st, "writtenAt": written})
	})
}
