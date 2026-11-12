//go:build !wasm

package main

import (
	"bytes"
	"compress/gzip"
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func heapProfileTestSetup(t *testing.T, over uint64) {
	t.Helper()
	oldOver, oldNow := heapProfileOverBytes, heapProfileNow
	t.Cleanup(func() {
		heapProfileOverBytes, heapProfileNow = oldOver, oldNow
		hostEnv.Lock()
		delete(hostEnv.m, heapProfileEnv)
		hostEnv.Unlock()
	})
	heapProfileOverBytes = over
}

func TestHeapProfileOffWritesNothing(t *testing.T) {
	heapProfileTestSetup(t, 0) // any heap is "over"
	t.Setenv(heapProfileEnv, "")
	if path, ok := heapProfileCheck(time.Time{}); ok {
		t.Fatalf("wrote %s with %s unset", path, heapProfileEnv)
	}
}

func TestHeapProfileUnderTheBarWritesNothing(t *testing.T) {
	heapProfileTestSetup(t, 1<<50)
	dir := t.TempDir()
	setHostEnv(heapProfileEnv, dir)
	if _, ok := heapProfileCheck(time.Time{}); ok {
		t.Fatal("wrote a profile under the bar")
	}
	if names, _ := os.ReadDir(dir); len(names) != 0 {
		t.Fatalf("dir holds %d files", len(names))
	}
}

func TestHeapProfileWritesANamedProfile(t *testing.T) {
	heapProfileTestSetup(t, 0)
	dir := filepath.Join(t.TempDir(), "profiles")
	setHostEnv(heapProfileEnv, dir)
	heapProfileNow = func() time.Time { return time.Date(2026, 11, 12, 3, 4, 5, 0, time.UTC) }

	path, ok := heapProfileCheck(time.Time{})
	if !ok {
		t.Fatal("no profile written over the bar")
	}
	if got, want := filepath.Base(path), "heap-20261112T030405Z-live"; len(got) < len(want) || got[:len(want)] != want {
		t.Fatalf("name %q, want prefix %q", got, want)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	zr, err := gzip.NewReader(bytes.NewReader(raw))
	if err != nil {
		t.Fatalf("not a gzipped pprof profile: %v", err)
	}
	body, _ := io.ReadAll(zr)
	if !bytes.Contains(body, []byte("inuse_space")) {
		t.Fatal("profile has no inuse_space sample type")
	}

	// Not again inside the gap.
	if _, ok := heapProfileCheck(heapProfileNow().Add(-time.Minute)); ok {
		t.Fatal("wrote a second profile inside heapProfileGap")
	}
}

func TestHeapProfileKeepsTheNewest(t *testing.T) {
	heapProfileTestSetup(t, 0)
	dir := t.TempDir()
	setHostEnv(heapProfileEnv, dir)
	os.WriteFile(filepath.Join(dir, "notes.txt"), []byte("mine"), 0o600)
	base := time.Date(2026, 11, 12, 0, 0, 0, 0, time.UTC)
	for i := range heapProfileKeep + 3 {
		heapProfileNow = func() time.Time { return base.Add(time.Duration(i) * time.Hour) }
		if _, ok := heapProfileCheck(time.Time{}); !ok {
			t.Fatal("no profile written")
		}
	}
	names, _ := filepath.Glob(filepath.Join(dir, "heap-*.pb.gz"))
	if len(names) != heapProfileKeep {
		t.Fatalf("%d profiles kept, want %d", len(names), heapProfileKeep)
	}
	if filepath.Base(names[0])[:20] != "heap-20261112T030000" {
		t.Fatalf("oldest kept %s, want the 4th written", names[0])
	}
	if _, err := os.Stat(filepath.Join(dir, "notes.txt")); err != nil {
		t.Fatal("pruning removed a file that is not a profile")
	}
}
