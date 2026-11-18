package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// The verified set is kept on disk across launches (go-nostr sigcache.go
// SaveVerifiedSigs / LoadVerifiedSigs). A restart is ResetSigCache, then a
// load. Nothing loaded may let a new or changed event through.

func restartSigCache(t *testing.T, path string) {
	t.Helper()
	if _, err := nostr.SaveVerifiedSigs(path); err != nil {
		t.Fatal(err)
	}
	nostr.ResetSigCache()
	if _, err := nostr.LoadVerifiedSigs(path); err != nil {
		t.Fatal(err)
	}
}

func TestVerifiedSigsSurviveARestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), verifiedSigsFile)
	nostr.ResetSigCache()
	evt, _ := sigCacheNote(t, "kept")
	mustVerify(t, evt, true, "first run")
	restartSigCache(t, path)
	mustVerify(t, evt, true, "after restart")
	if hits, misses := nostr.SigCacheStats(); hits != 1 || misses != 0 {
		t.Fatalf("hits=%d misses=%d after restart, want 1 and 0", hits, misses)
	}
}

func TestVerifiedSigsNeverPassAChangedEventAfterARestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), verifiedSigsFile)
	nostr.ResetSigCache()
	evt, _ := sigCacheNote(t, "original")
	other, _ := sigCacheNote(t, "someone else")
	mustVerify(t, evt, true, "original")
	mustVerify(t, other, true, "other")
	restartSigCache(t, path)

	cases := map[string]func(e *nostr.Event){
		"content, same claimed id": func(e *nostr.Event) { e.Content = "forged" },
		"created_at":               func(e *nostr.Event) { e.CreatedAt++ },
		"pubkey swapped":           func(e *nostr.Event) { e.PubKey = other.PubKey },
		"sig from another event":   func(e *nostr.Event) { e.Sig = other.Sig },
		"sig one byte off":         func(e *nostr.Event) { e.Sig = sigCacheFlip(e.Sig, 10) },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			e := evt
			mutate(&e)
			mustVerify(t, e, false, name)
		})
	}
}

func TestVerifiedSigsFailuresAreNeverSaved(t *testing.T) {
	path := filepath.Join(t.TempDir(), verifiedSigsFile)
	nostr.ResetSigCache()
	evt, _ := sigCacheNote(t, "x")
	bad := evt
	bad.Sig = sigCacheFlip(bad.Sig, 0)
	mustVerify(t, bad, false, "bad sig")
	if n, _ := nostr.SaveVerifiedSigs(path); n != 0 {
		t.Fatalf("saved %d keys, want none: only passes are kept", n)
	}
	restartSigCache(t, path)
	mustVerify(t, bad, false, "bad sig after restart")
}

func TestVerifiedSigsForeignOrCutFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, verifiedSigsFile)
	os.WriteFile(path, []byte("not ours, not ours, not ours, not ours"), 0o644)
	nostr.ResetSigCache()
	if n, err := nostr.LoadVerifiedSigs(path); err == nil || n != 0 {
		t.Fatalf("foreign file: n=%d err=%v, want an error and nothing loaded", n, err)
	}
	if n, err := nostr.LoadVerifiedSigs(filepath.Join(dir, "missing")); err != nil || n != 0 {
		t.Fatalf("missing file: n=%d err=%v, want nothing and no error", n, err)
	}

	evt, _ := sigCacheNote(t, "a")
	evt2, _ := sigCacheNote(t, "b")
	mustVerify(t, evt, true, "a")
	mustVerify(t, evt2, true, "b")
	if n, _ := nostr.SaveVerifiedSigs(path); n != 2 {
		t.Fatalf("saved %d, want 2", n)
	}
	data, _ := os.ReadFile(path)
	os.WriteFile(path, data[:len(data)-5], 0o644) // cut mid-key
	nostr.ResetSigCache()
	if n, err := nostr.LoadVerifiedSigs(path); err != nil || n != 1 {
		t.Fatalf("cut file: n=%d err=%v, want the 1 whole key", n, err)
	}
}

// The app keeps the file only when it has a store folder; tests and the CLI
// never write one into the working directory.
func TestKeepVerifiedSigsNeedsAStoreFolder(t *testing.T) {
	t.Setenv("DATABASE_PATH", "")
	if p := verifiedSigsPath(); p != "" {
		t.Fatalf("path %q with no DATABASE_PATH", p)
	}
	dir := t.TempDir()
	t.Setenv("DATABASE_PATH", filepath.Join(dir, "db")+"/")
	if p := verifiedSigsPath(); p != filepath.Join(dir, verifiedSigsFile) {
		t.Fatalf("path %q, want beside the stores", p)
	}
}

// keepVerifiedSigs loads at start and saves when the context ends.
func TestKeepVerifiedSigsLoadsAndSaves(t *testing.T) {
	path := filepath.Join(t.TempDir(), verifiedSigsFile)
	nostr.ResetSigCache()
	evt, _ := sigCacheNote(t, "run one")
	mustVerify(t, evt, true, "run one")
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { keepVerifiedSigs(ctx, path); close(done) }()
	time.Sleep(50 * time.Millisecond)
	evt2, _ := sigCacheNote(t, "during")
	mustVerify(t, evt2, true, "during")
	cancel()
	<-done

	nostr.ResetSigCache()
	ctx2, cancel2 := context.WithCancel(context.Background())
	done2 := make(chan struct{})
	go func() { keepVerifiedSigs(ctx2, path); close(done2) }()
	time.Sleep(50 * time.Millisecond)
	mustVerify(t, evt, true, "run one, next launch")
	mustVerify(t, evt2, true, "during, next launch")
	if _, misses := nostr.SigCacheStats(); misses != 0 {
		t.Fatalf("misses=%d on the next launch, want both loaded", misses)
	}
	cancel2()
	<-done2
}
