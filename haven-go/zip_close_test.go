//go:build !(js && wasm)

package main

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// failingOut takes no bytes at all, so nothing fails until the zip flushes
// on Close: the index write a full disk breaks.
type failingOut struct{ closed bool }

var errDiskFull = errors.New("no space left on device")

func (w *failingOut) Write(p []byte) (int, error) { return 0, errDiskFull }
func (w *failingOut) Close() error                { w.closed = true; return nil }

// Audit I R2: a zip whose index could not be written is an error, not a
// backup.
func TestZipDirectoryReportsAFailedClose(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("small"), 0o600); err != nil {
		t.Fatal(err)
	}
	out := &failingOut{}
	if err := zipDirectoryTo(dir, out); !errors.Is(err, errDiskFull) {
		t.Fatalf("zip onto a full disk: %v, want the write error", err)
	}
	if !out.closed {
		t.Fatal("the file was left open")
	}
	ok := filepath.Join(t.TempDir(), "ok.zip")
	if err := ZipDirectory(dir, ok); err != nil {
		t.Fatalf("good zip: %v", err)
	}
	if err := UnzipDirectory(ok, t.TempDir()); err != nil {
		t.Fatalf("good zip does not open: %v", err)
	}
}
