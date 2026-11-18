package main

import (
	"context"
	"log/slog"
	"path/filepath"
	"strings"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// The signature checks that passed are kept on disk (go-nostr sigcache.go
// SaveVerifiedSigs), next to the event stores, so a relaunch does not check
// again every note the relays send back.

const verifiedSigsFile = "verified_sigs.bin"

var verifiedSigsSaveEvery = 30 * time.Second

// verifiedSigsPath is the file beside the stores (the parent of
// DATABASE_PATH, which every app sets), or "" for no file (CLI, tests).
func verifiedSigsPath() string {
	if db := hostGetenv("DATABASE_PATH"); db != "" {
		return filepath.Join(filepath.Dir(strings.TrimRight(db, "/")), verifiedSigsFile)
	}
	return ""
}

// keepVerifiedSigs loads the saved checks, then saves them every
// verifiedSigsSaveEvery while new ones arrive, and once more when ctx ends.
func keepVerifiedSigs(ctx context.Context, path string) {
	if path == "" {
		return
	}
	if n, err := nostr.LoadVerifiedSigs(path); err != nil {
		slog.Warn("verified signatures not loaded", "error", err)
	} else if n > 0 {
		slog.Info("verified signatures loaded", "count", n)
	}
	_, saved := nostr.SigCacheStats()
	save := func() {
		_, misses := nostr.SigCacheStats()
		if misses == saved {
			return
		}
		if _, err := nostr.SaveVerifiedSigs(path); err != nil {
			slog.Warn("verified signatures not saved", "error", err)
			return
		}
		saved = misses
	}
	t := time.NewTicker(verifiedSigsSaveEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			save()
			return
		case <-t.C:
			save()
		}
	}
}
