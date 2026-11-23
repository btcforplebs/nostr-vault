//go:build !cshared && !(js && wasm)

package main

// The desktop Vault status for a Linux box's web dashboard (step 4):
// havend runs this engine as a child and talks to it through files in the
// vault folder, the engine's working directory (box_jobs.go). Here the
// engine writes its status read (vault_status.go) to vault_status.json
// every vaultStatusFileEvery; havend serves it at GET /api/box/vault-status
// (internal/box/routes_vault_status.go). Nothing is signed or sent.

import (
	"context"
	"encoding/json"
	"log"
	"os"
	"time"
)

const (
	vaultStatusFileName  = "vault_status.json"
	vaultStatusFileEvery = 15 * time.Second
)

// writeVaultStatusFile writes st to path through a temp file and a rename.
func writeVaultStatusFile(path string, st vaultStatus) error {
	b, err := json.Marshal(st)
	if err != nil {
		return err
	}
	if err := os.WriteFile(path+".tmp", b, 0o600); err != nil {
		return err
	}
	return os.Rename(path+".tmp", path)
}

// startVaultStatusFile keeps vault_status.json up to date until ctx ends.
func startVaultStatusFile(ctx context.Context, spawn func(string, func())) {
	spawn("vaultStatusFile", func() {
		t := time.NewTicker(vaultStatusFileEvery)
		defer t.Stop()
		for {
			if err := writeVaultStatusFile(vaultStatusFileName, readVaultStatus()); err != nil {
				log.Printf("vault status file: %v", err)
			}
			select {
			case <-ctx.Done():
				return
			case <-t.C:
			}
		}
	})
}
