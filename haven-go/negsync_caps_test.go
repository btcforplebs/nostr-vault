package main

import (
	"context"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// resetNegCaps empties the in-memory cache and forgets that it was loaded,
// as a relaunch would.
func resetNegCaps() {
	negCaps.Range(func(k, _ any) bool { negCaps.Delete(k); return true })
	negCapsLoadOnce = sync.Once{}
}

func TestNegCapsUnsupportedSurvivesRelaunch(t *testing.T) {
	old := negCapsFile
	negCapsFile = filepath.Join(t.TempDir(), "negentropy_caps.json")
	t.Cleanup(func() { negCapsFile = old; resetNegCaps() })
	resetNegCaps()

	url := "wss://no-negentropy.invalid"
	markNegentropyUnsupported(url)

	resetNegCaps() // relaunch
	if relaySupportsNegentropy(context.Background(), url) {
		t.Fatal("relay found unsupported before the relaunch was probed again")
	}

	// A later success clears the saved answer.
	markNegentropySupported(url)
	resetNegCaps()
	negCapsLoadOnce.Do(loadNegCaps)
	if _, ok := negCaps.Load(nostr.NormalizeURL(url)); ok {
		t.Fatal("a relay that synced fine is still saved as unsupported")
	}
}

func TestNegCapsExpiredEntryIsNotLoaded(t *testing.T) {
	old := negCapsFile
	negCapsFile = filepath.Join(t.TempDir(), "negentropy_caps.json")
	t.Cleanup(func() { negCapsFile = old; resetNegCaps() })
	resetNegCaps()

	key := nostr.NormalizeURL("wss://stale.invalid")
	negCaps.Store(key, negCap{supported: false, checkedAt: time.Now().Add(-negCapRetryTTL + time.Minute)})
	saveNegCaps()
	resetNegCaps()
	negCapsLoadOnce.Do(loadNegCaps)
	if _, ok := negCaps.Load(key); !ok {
		t.Fatal("an answer inside the TTL was not loaded")
	}
	negCaps.Store(key, negCap{supported: false, checkedAt: time.Now().Add(-negCapRetryTTL - time.Minute)})
	saveNegCaps()
	resetNegCaps()
	negCapsLoadOnce.Do(loadNegCaps)
	if _, ok := negCaps.Load(key); ok {
		t.Fatal("an answer past the TTL was loaded")
	}
}
