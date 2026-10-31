package box

import (
	"os"
	"path/filepath"
	"testing"
)

// A sparse file (a running Badger value log) counts by the space it takes.
func TestStorageCountsSparseFilesByDiskUse(t *testing.T) {
	vault := t.TempDir()
	os.MkdirAll(filepath.Join(vault, "db", "outbox"), 0o700)
	f, err := os.Create(filepath.Join(vault, "db", "outbox", "000001.vlog"))
	if err != nil {
		t.Fatal(err)
	}
	f.Truncate(1 << 30)
	f.Close()
	st := (&StorageMeter{}).Measure(vault)
	if st.DatabaseBytes >= 1<<20 {
		t.Fatalf("sparse 1 GiB file counted as %d bytes", st.DatabaseBytes)
	}
}
