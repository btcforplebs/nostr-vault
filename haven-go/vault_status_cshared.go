//go:build cshared

package main

import "C"

import (
	"context"
	"encoding/json"
)

func init() { vaultStatusCshared = true }

//export VaultStatusC
func VaultStatusC() *C.char {
	// JSON of vaultStatus (vault_status.go): what the trust rank crawler,
	// the distant posts job and the rank hand-off are doing. Reads small
	// files; a new result file is decoded once. The caller frees the string.
	b, _ := json.Marshal(readVaultStatus())
	return C.CString(string(b))
}

//export VaultStatusFromC
func VaultStatusFromC(peer *C.char, base *C.char) *C.char {
	// A phone's read of its desktop Vault's status over the mesh
	// (copyv2_status_client.go): {"status": {...}} or {"error": "<code>"}.
	// Blocks up to 15 s: call it off the main thread. The caller frees it.
	return C.CString(string(vaultStatusFromJSON(context.Background(), C.GoString(peer), C.GoString(base))))
}
