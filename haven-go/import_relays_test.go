//go:build !cshared

package main

import (
	"context"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"

	"github.com/nbd-wtf/go-nostr"
)

// A seed relay that fails the startup check must not be fetched from again:
// each 10-day import window would re-dial it and wait out the connect timeout.
func TestImportRelaysDropsUnreachableSeeds(t *testing.T) {
	live := newFakeMac(t, false, 0)
	deadSrv := httptest.NewServer(nil)
	dead := "ws" + strings.TrimPrefix(deadSrv.URL, "http")
	deadSrv.Close()

	oldConfig, oldPool, oldReachable := config, pool, reachableImportRelays.Load()
	t.Cleanup(func() {
		config, pool = oldConfig, oldPool
		reachableImportRelays.Store(oldReachable)
	})
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	pool = nostr.NewSimplePool(ctx)
	reachableImportRelays.Store(nil)
	config.ImportSeedRelays = []string{dead, live.url}

	if got := importRelays(); !slices.Equal(got, config.ImportSeedRelays) {
		t.Fatalf("before the check, importRelays() = %v, want all seeds", got)
	}
	if !ensureImportRelays() {
		t.Fatal("ensureImportRelays() = false with one reachable relay")
	}
	if got := importRelays(); !slices.Equal(got, []string{live.url}) {
		t.Fatalf("importRelays() = %v, want only %s", got, live.url)
	}

	config.ImportSeedRelays = []string{dead}
	if ensureImportRelays() {
		t.Fatal("ensureImportRelays() = true with no reachable relay")
	}
}
