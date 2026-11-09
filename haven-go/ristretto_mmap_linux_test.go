//go:build linux

package main

import (
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"testing"
	_ "unsafe" // for go:linkname

	"github.com/dgraph-io/ristretto/v2/z"
	"golang.org/x/sys/unix"
)

// xsysMapper mirrors the head of x/sys's unexported Linux mapper
// (mremapMmapper embeds mmapper, whose first fields are a Mutex and the
// active map). Only those two fields are read.
type xsysMapper struct {
	sync.Mutex
	active map[*byte][]byte
}

//go:linkname xsysMapperPtr golang.org/x/sys/unix.mapper
var xsysMapperPtr *xsysMapper

func xsysActiveMappings() int {
	m := xsysMapperPtr
	m.Lock()
	defer m.Unlock()
	return len(m.active)
}

func newSizedFile(t *testing.T, name string, size int64) *os.File {
	t.Helper()
	f, err := os.OpenFile(filepath.Join(t.TempDir(), name), os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.Close() })
	if err := f.Truncate(size); err != nil {
		t.Fatal(err)
	}
	return f
}

// TestXSysMapperMirrorSeesMappings is the positive control for the test
// below: a plain unix.Mmap must show up in the mirrored map, and
// unix.Munmap must remove it. If x/sys changes its layout this fails
// instead of letting the leak test pass on a misread.
func TestXSysMapperMirrorSeesMappings(t *testing.T) {
	f := newSizedFile(t, "control", 1<<20)
	before := xsysActiveMappings()
	b, err := unix.Mmap(int(f.Fd()), 0, 1<<20, unix.PROT_READ, unix.MAP_SHARED)
	if err != nil {
		t.Fatal(err)
	}
	if got := xsysActiveMappings(); got != before+1 {
		t.Fatalf("after unix.Mmap: %d active mappings, want %d", got, before+1)
	}
	if err := unix.Munmap(b); err != nil {
		t.Fatal(err)
	}
	if got := xsysActiveMappings(); got != before {
		t.Fatalf("after unix.Munmap: %d active mappings, want %d", got, before)
	}
}

// TestRistrettoMmapLeavesNoStaleXSysEntry guards the patch in
// third_party/ristretto/z/mmap_linux.go. Badger maps its files through
// ristretto's z package and unmaps them with raw syscalls. If z maps with
// unix.Mmap, x/sys keeps a pointer to each freed mapping's last byte
// forever, and on Android the GC later aborts on it ("found bad pointer in
// Go heap"). Nothing z maps may stay in x/sys's table after it is unmapped,
// whether by Munmap or by a Truncate (mremap) followed by Close.
func TestRistrettoMmapLeavesNoStaleXSysEntry(t *testing.T) {
	before := xsysActiveMappings()

	var maps [][]byte
	for i := 0; i < 8; i++ {
		f := newSizedFile(t, "map", 1<<20)
		b, err := z.Mmap(f, true, 1<<20)
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
	if got := xsysActiveMappings(); got != before {
		t.Fatalf("z.Mmap + z.Munmap left %d stale x/sys mappings", got-before)
	}

	mf, err := z.OpenMmapFile(filepath.Join(t.TempDir(), "grow"), os.O_RDWR|os.O_CREATE, 1<<20)
	if err != nil && err != z.NewFile {
		t.Fatal(err)
	}
	if err := mf.Truncate(4 << 20); err != nil {
		t.Fatal(err)
	}
	if err := mf.Close(-1); err != nil {
		t.Fatal(err)
	}
	if got := xsysActiveMappings(); got != before {
		t.Fatalf("z.OpenMmapFile + Truncate + Close left %d stale x/sys mappings", got-before)
	}
	runtime.KeepAlive(mf)
}
