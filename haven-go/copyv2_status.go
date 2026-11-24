//go:build !(js && wasm)

package main

// The desktop Vault's status over the mesh (Logen 2026-11-23): an owner's
// own paired devices read what their Haven's trust rank crawler, distant
// posts job and rank hand-off are doing (vault_status.go), to show "Your
// desktop Vault" in Your Space. Like the rank copy (copyv2_trust.go) it
// rides the copy token, which is bound to a paired device's mesh key; the
// account key is never used or asked for, and nothing is signed.

import "net/http"

// serveSyncStatus is GET /copy/v2/sync/status, behind the device's bearer.
// The answer is vaultStatus as JSON, for the accounts this Haven ranks.
func (s *copyServer) serveSyncStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.NotFound(w, r)
		return
	}
	copyJSON(w, http.StatusOK, readVaultStatus())
}
