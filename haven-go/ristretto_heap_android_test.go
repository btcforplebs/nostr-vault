//go:build android

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/dgraph-io/ristretto/v2/z"
)

// TestRistrettoUnmapThenHeapGrowth is the crash itself, Android only. It
// maps and unmaps 256 MiB the way Badger does, then grows the Go heap to
// 1 GiB. On Android's 39-bit address space the heap lands next to the freed
// mappings; with an unpatched ristretto z the GC aborts the process with
// "found bad pointer in Go heap" (9 of 10 runs on an arm64 emulator).
// Run on an emulator: go test -c for GOOS=android, push, and run with
// -test.run TestRistrettoUnmapThenHeapGrowth.
func TestRistrettoUnmapThenHeapGrowth(t *testing.T) {
	if testing.Short() {
		t.Skip("grows the heap to 1 GiB")
	}
	dir := t.TempDir()
	const n, size = 256, 1 << 20
	maps := make([][]byte, 0, n)
	for i := 0; i < n; i++ {
		f, err := os.OpenFile(filepath.Join(dir, fmt.Sprintf("%03d.vlog", i)), os.O_RDWR|os.O_CREATE, 0o600)
		if err != nil {
			t.Fatal(err)
		}
		if err := f.Truncate(size); err != nil {
			t.Fatal(err)
		}
		b, err := z.Mmap(f, true, size)
		f.Close()
		if err != nil {
			t.Fatal(err)
		}
		b[len(b)-1] = 1
		maps = append(maps, b)
	}
	for _, b := range maps {
		if err := z.Munmap(b); err != nil {
			t.Fatal(err)
		}
	}
	maps = nil

	const obj = 576 // new([72]uint64)
	keep := make([]*[72]uint64, 0, (1<<30)/obj)
	for i := 0; i < (1<<30)/obj; i++ {
		keep = append(keep, new([72]uint64))
		if i%((32<<20)/obj) == 0 {
			runtime.GC()
		}
	}
	runtime.GC()
	runtime.KeepAlive(keep)
}
