//go:build !(js && wasm)

package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The hourly sweep drops a copy past copyKeepFor and a folder no job owns,
// and keeps a fresh copy and a build still running, whatever its age.
func TestCopySweepKeepsLiveCopiesAndDropsOldOnes(t *testing.T) {
	root := t.TempDir()
	now := time.Date(2026, 11, 26, 12, 0, 0, 0, time.UTC)
	s := &copyServer{jobs: map[string]*copyJob{}, seen: map[string]time.Time{}, now: func() time.Time { return now }, cacheDir: root}
	mk := func(id, state string, built time.Time) string {
		dir := filepath.Join(root, id)
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "media.zip"), []byte("zip"), 0o600); err != nil {
			t.Fatal(err)
		}
		if state != "" {
			s.jobs[id] = &copyJob{manifest: copyManifest{ID: id, State: state}, dir: dir, built: built}
		}
		return dir
	}
	id := func(c string) string { return strings.Repeat(c, 32) }
	fresh := mk(id("a"), "ready", now.Add(-time.Hour))
	old := mk(id("b"), "ready", now.Add(-48*time.Hour))
	building := mk(id("c"), "building", now.Add(-48*time.Hour))
	orphan := mk(id("d"), "", time.Time{})
	// Not a copy id: someone else's folder or file in a "copy" dir we don't own.
	foreign := mk("photos", "", time.Time{})
	foreignFile := filepath.Join(root, "notes.txt")
	if err := os.WriteFile(foreignFile, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}

	s.sweepNow()

	for _, keep := range []string{fresh, building, foreign, foreignFile} {
		if _, err := os.Stat(keep); err != nil {
			t.Errorf("%s removed: %v", filepath.Base(keep), err)
		}
	}
	for _, gone := range []string{old, orphan} {
		if _, err := os.Stat(gone); !os.IsNotExist(err) {
			t.Errorf("%s kept", filepath.Base(gone))
		}
	}
	if _, ok := s.jobs[id("b")]; ok {
		t.Error("old job still listed")
	}
	if _, ok := s.jobs[id("a")]; !ok {
		t.Error("fresh job dropped")
	}
}

// At engine start nothing is in memory, so a copy an earlier run left is gone
// without waiting for another device to ask; the folder outside stays.
func TestCopySweeperClearsEarlierRunAtStart(t *testing.T) {
	root := t.TempDir()
	cache := filepath.Join(root, copyCacheDir)
	left := filepath.Join(cache, strings.Repeat("e", 32))
	if err := os.MkdirAll(left, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(left, "media.zip"), make([]byte, 1024), 0o600); err != nil {
		t.Fatal(err)
	}
	beside := filepath.Join(root, "blossom")
	if err := os.MkdirAll(beside, 0o700); err != nil {
		t.Fatal(err)
	}
	saved := copyV2
	copyV2 = &copyServer{jobs: map[string]*copyJob{}, seen: map[string]time.Time{}, now: time.Now, cacheDir: cache}
	t.Cleanup(func() { copyV2 = saved })
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	startCopySweeper(ctx)

	if _, err := os.Stat(left); !os.IsNotExist(err) {
		t.Error("earlier run's copy kept at start")
	}
	if _, err := os.Stat(cache); err != nil {
		t.Errorf("copy folder itself removed: %v", err)
	}
	if _, err := os.Stat(beside); err != nil {
		t.Errorf("folder beside the copy dir touched: %v", err)
	}
}
