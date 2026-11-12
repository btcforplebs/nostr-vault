//go:build !wasm

package main

import (
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"runtime/metrics"
	"runtime/pprof"
	"slices"
	"strings"
	"time"
)

// A heap profile on demand, for a relay whose Go heap grows past what it
// should hold (RESEARCH/NV_MAC_RELAY_HEAP_2026_11_12.md): nothing else in the
// relay can say what the heap is made of.
//
// Off unless HAVEN_HEAP_PROFILE_DIR names a directory (process environment,
// the host app's settings or .env, read through hostGetenv). While it is set,
// every heapProfileEvery the live heap is read, and when it is over
// heapProfileOverBytes a heap profile is written there as
// heap-<UTC time>-live<MB>MB.pb.gz, at most one per heapProfileGap, keeping
// the newest heapProfileKeep. Read one anywhere with
// `go tool pprof -top -sample_index=inuse_space <file>`: the profile carries
// function names, so it needs no binary or symbols.

const heapProfileEnv = "HAVEN_HEAP_PROFILE_DIR"

var (
	heapProfileEvery     = 30 * time.Second
	heapProfileGap       = 5 * time.Minute
	heapProfileOverBytes = uint64(1 << 30) // 1 GiB live
	heapProfileKeep      = 10
	heapProfileNow       = time.Now
)

func init() {
	go func() {
		var last time.Time
		for range time.Tick(heapProfileEvery) {
			if path, ok := heapProfileCheck(last); ok {
				last = heapProfileNow()
				slog.Warn("🧠 wrote a heap profile", "path", path)
			}
		}
	}()
}

// heapProfileCheck writes a profile if the setting is on, the live heap is
// over the bar and the last one was written over heapProfileGap ago. It
// returns the file written.
func heapProfileCheck(last time.Time) (string, bool) {
	dir := strings.TrimSpace(hostGetenv(heapProfileEnv))
	if dir == "" {
		return "", false
	}
	live := liveHeapBytes()
	if live <= heapProfileOverBytes {
		return "", false
	}
	now := heapProfileNow()
	if !last.IsZero() && now.Sub(last) < heapProfileGap {
		return "", false
	}
	path, err := writeHeapProfile(dir, now, live)
	if err != nil {
		slog.Error("🚫 could not write a heap profile", "dir", dir, "error", err)
		return "", false
	}
	pruneHeapProfiles(dir, heapProfileKeep)
	return path, true
}

// liveHeapBytes is the heap the last GC found reachable: what the GC has to
// keep, not garbage waiting for the next cycle.
func liveHeapBytes() uint64 {
	s := []metrics.Sample{{Name: "/gc/heap/live:bytes"}}
	metrics.Read(s)
	if s[0].Value.Kind() != metrics.KindUint64 {
		return 0
	}
	return s[0].Value.Uint64()
}

func writeHeapProfile(dir string, now time.Time, live uint64) (string, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	name := fmt.Sprintf("heap-%s-live%dMB.pb.gz", now.UTC().Format("20060102T150405Z"), live>>20)
	path := filepath.Join(dir, name)
	tmp := path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return "", err
	}
	err = pprof.Lookup("heap").WriteTo(f, 0)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(tmp, path)
	}
	if err != nil {
		os.Remove(tmp)
		return "", err
	}
	return path, nil
}

// pruneHeapProfiles keeps the newest keep profiles in dir (names sort by time)
// and touches nothing else there.
func pruneHeapProfiles(dir string, keep int) {
	names, _ := filepath.Glob(filepath.Join(dir, "heap-*.pb.gz"))
	slices.Sort(names)
	for len(names) > keep {
		os.Remove(names[0])
		names = names[1:]
	}
}
