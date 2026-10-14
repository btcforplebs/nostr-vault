package main

import (
	"fmt"
	"math/rand/v2"
	"runtime"
	"testing"
)

// newTestBackend is this platform's fallback database at a fresh path:
// Badger in a temp dir natively; on js/wasm node's memory store, or in a
// browser an IndexedDB database (there is no filesystem for t.TempDir). The
// browser name is random, since chrome_exec runs every test twice in one
// profile. Not initialised.
func newTestBackend(t *testing.T, name string) DBBackend {
	t.Helper()
	if runtime.GOOS == "js" {
		return fallbackBackend(fmt.Sprintf("db/test-%s-%016x", name, rand.Uint64()))
	}
	return fallbackBackend(t.TempDir() + "/" + name)
}
