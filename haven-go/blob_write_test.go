//go:build !(js && wasm)

package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"github.com/spf13/afero"
)

// pausingReader hands out the first half, signals, waits for resume, then
// the rest: a slow download.
type pausingReader struct {
	data           []byte
	pos            int
	paused, resume chan struct{}
}

func (p *pausingReader) Read(b []byte) (int, error) {
	half := len(p.data) / 2
	if p.pos == half && p.paused != nil {
		close(p.paused)
		p.paused = nil
		<-p.resume
	}
	end := len(p.data)
	if p.pos < half {
		end = half
	}
	if p.pos >= len(p.data) {
		return 0, io.EOF
	}
	n := copy(b, p.data[p.pos:end])
	p.pos += n
	return n, nil
}

// failingReader signals on its first Read, waits, then fails without
// giving a byte: a download cut off before anything arrived.
type failingReader struct {
	reading, fail chan struct{}
}

func (f *failingReader) Read([]byte) (int, error) {
	close(f.reading)
	<-f.fail
	return 0, errors.New("connection reset")
}

func blobWriteDir(t *testing.T) {
	t.Helper()
	prev := config
	t.Cleanup(func() { config = prev })
	dir := t.TempDir()
	config.BlossomPath = dir + string(filepath.Separator)
}

// Tron's trace (#1798 review): write A of a blob is mid-stream when write B
// of the same blob starts, A finishes and renames, then B fails. With one
// shared <sha>.tmp (O_TRUNC) B's open emptied the file A was writing, so A
// renamed a file whose first half was zeros, and the truncated <sha> counted
// as stored forever. Each write now has its own temp file.
func TestWriteBlobFileOverlappingWritesOfOneBlob(t *testing.T) {
	blobWriteDir(t)
	data := bytes.Repeat([]byte("0123456789abcdef"), 1<<14)
	sum := sha256.Sum256(data)
	sha := hex.EncodeToString(sum[:])
	osfs := afero.NewOsFs()

	aPaused, aResume := make(chan struct{}), make(chan struct{})
	a := &pausingReader{data: data, paused: aPaused, resume: aResume}
	b := &failingReader{reading: make(chan struct{}), fail: make(chan struct{})}
	var aOK bool
	var aErr, bErr error
	aDone, bDone := make(chan struct{}), make(chan struct{})
	go func() { defer close(aDone); aOK, aErr = writeBlobFile(osfs, sha, a) }()
	<-aPaused // A is mid-stream
	go func() { defer close(bDone); _, bErr = writeBlobFile(osfs, sha, b) }()
	<-b.reading // B has opened its file
	close(aResume)
	<-aDone
	close(b.fail)
	<-bDone

	if !aOK || aErr != nil {
		t.Fatalf("write A: ok=%v err=%v", aOK, aErr)
	}
	if bErr == nil {
		t.Fatal("the cut write B reported success")
	}
	got, err := os.ReadFile(config.BlossomPath + sha)
	if err != nil || !bytes.Equal(got, data) {
		sum := sha256.Sum256(got)
		t.Fatalf("stored blob is not whole: %d of %d bytes, hash ok=%v (%v)", len(got), len(data), hex.EncodeToString(sum[:]) == sha, err)
	}
	left, _ := filepath.Glob(config.BlossomPath + "*.tmp")
	if len(left) != 0 {
		t.Fatalf("temp files left: %v", left)
	}
}

// Many writers of one blob at once, through every caller's path: all succeed
// and the stored file is whole.
func TestWriteBlobFileManyWritersOfOneBlob(t *testing.T) {
	blobWriteDir(t)
	data := bytes.Repeat([]byte("media "), 1<<16)
	sum := sha256.Sum256(data)
	sha := hex.EncodeToString(sum[:])
	var wg sync.WaitGroup
	errs := make(chan error, 16)
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if ok, err := writeBlobFile(afero.NewOsFs(), sha, bytes.NewReader(data)); !ok || err != nil {
				errs <- errors.Join(err, errors.New("not stored"))
			}
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(config.BlossomPath + sha)
	if !bytes.Equal(got, data) {
		t.Fatalf("stored blob is not whole: %d bytes", len(got))
	}
}

// A file that doesn't hash to its name is never stored, and leaves nothing.
func TestWriteBlobFileRefusesWrongHash(t *testing.T) {
	blobWriteDir(t)
	sum := sha256.Sum256([]byte("other"))
	sha := hex.EncodeToString(sum[:])
	ok, err := writeBlobFile(afero.NewOsFs(), sha, io.LimitReader(bytes.NewReader([]byte("bytes")), 5))
	if ok || err != nil {
		t.Fatalf("ok=%v err=%v", ok, err)
	}
	if left, _ := filepath.Glob(config.BlossomPath + "*"); len(left) != 0 {
		t.Fatalf("files left: %v", left)
	}
}
