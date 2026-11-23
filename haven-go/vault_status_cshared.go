//go:build cshared

package main

import "C"

import "encoding/json"

func init() { vaultStatusCshared = true }

//export VaultStatusC
func VaultStatusC() *C.char {
	// JSON of vaultStatus (vault_status.go): what the trust rank crawler,
	// the distant posts job and the rank hand-off are doing. Reads small
	// files; a new result file is decoded once. The caller frees the string.
	b, _ := json.Marshal(readVaultStatus())
	return C.CString(string(b))
}
