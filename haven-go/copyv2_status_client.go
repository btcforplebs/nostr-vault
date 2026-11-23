//go:build !(js && wasm)

package main

// A device reads its desktop Vault's status (copyv2_status.go) to show
// "Your desktop Vault" in Your space. The same copy token as a catch-up
// (a paired device's mesh key); the account key is never used and nothing
// is signed. Asked only while the card is on screen; it never starts or
// changes a copy.

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"time"
)

const (
	vaultStatusFetchTimeout = 15 * time.Second
	vaultStatusMaxSize      = 1 << 20
)

// fetchVaultStatus asks peer (at base, the mesh's loopback for its
// own-device port) for its status. Errors carry a copy error code:
// not_paired (no token for that peer yet), auth_refused, not_found (an
// engine from before the read), bad_answer, or unreachable.
func fetchVaultStatus(ctx context.Context, peer, base string) (vaultStatus, error) {
	var st vaultStatus
	c := newCopyClient(peer, base)
	c.token = copyPeerToken(peer)
	if c.token == "" {
		return st, copyErr("not_paired")
	}
	c.http.Timeout = vaultStatusFetchTimeout
	resp, err := c.do(ctx, http.MethodGet, "/copy/v2/sync/status", nil, nil)
	if err != nil {
		return st, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return st, statusError(resp.StatusCode)
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, vaultStatusMaxSize+1))
	if err != nil {
		return st, err
	}
	if len(raw) > vaultStatusMaxSize || json.Unmarshal(raw, &st) != nil || st.Version < 1 || st.State == "" {
		return vaultStatus{}, copyErr("bad_answer")
	}
	return st, nil
}

// vaultStatusFromJSON is what VaultStatusFromC hands the app: the status,
// or the error code.
func vaultStatusFromJSON(ctx context.Context, peer, base string) []byte {
	st, err := fetchVaultStatus(ctx, peer, base)
	var out any
	if err != nil {
		out = map[string]string{"error": copyErrorCode(err)}
	} else {
		out = map[string]any{"status": st}
	}
	b, _ := json.Marshal(out)
	return b
}
