//go:build js && wasm

package main

import (
	"bytes"
	"errors"
	"io"
	"os"
	"syscall/js"
	"testing"

	"github.com/spf13/afero"
)

// Blossom's blobs in the browser, through newRootFs and openBlobFile as
// havenStart and loadBlob use them. Run in Chrome with idbstore's harness,
// which runs the binary twice with a real page reload in between:
//
//	GOOS=js GOARCH=wasm go test -exec "$PWD/idbstore/harness/chrome_exec" -run '^TestBlob' .
//
// Phase 1 stores; phase 2 (a new document and Go runtime, same IndexedDB)
// reads them back, checks another account can't, and signs out. Run once
// without the harness, phase 2 follows phase 1 on a fresh blobFs.
var (
	blobA    = []byte("a photo, as bytes")
	blobAJpg = []byte("a photo stored with its extension")
)

const (
	shaA    = "aa00000000000000000000000000000000000000000000000000000000000000"
	shaAJpg = "ab00000000000000000000000000000000000000000000000000000000000000"
)

func TestBlobsSurviveReloadPerAccount(t *testing.T) {
	// "blossom/" puts blobs in a directory; the default, "blossom", puts
	// "blossom<sha>" at the root, where afero.Glob lists ".".
	t.Run("dir", func(t *testing.T) { testBlobsSurviveReload(t, "blossom/", "blobtest-dir-a", "blobtest-dir-b") })
	t.Run("root", func(t *testing.T) { testBlobsSurviveReload(t, "blossom", "blobtest-root-a", "blobtest-root-b") })
}

func testBlobsSurviveReload(t *testing.T, blossomPath, acctA, acctB string) {
	if runningUnderNode() {
		t.Skip("no IndexedDB under node: newRootFs keeps blobs in memory there")
	}
	defer func(p, b string, f afero.Fs) { storePrefix, config.BlossomPath, fs = p, b, f }(storePrefix, config.BlossomPath, fs)
	config.BlossomPath = blossomPath

	phase := os.Getenv("IDBSTORE_PHASE")
	if phase != "2" {
		for _, acct := range []string{acctA, acctB} {
			if got := deleteIDB(t, storeName(acct, "db/blobs")); got != "" {
				t.Fatalf("clearing %s: %s", acct, got)
			}
		}
		bootBlobs(t, acctA)
		storeBlob(t, shaA, blobA)
		if err := afero.WriteFile(fs, config.BlossomPath+shaAJpg+".jpg", blobAJpg, 0o644); err != nil {
			t.Fatal(err)
		}
		// The temp file never reaches IndexedDB; only the renamed blob does.
		keys, err := fs.(*blobFs).keys()
		if err != nil {
			t.Fatal(err)
		}
		if want := []string{blossomPath + shaA, blossomPath + shaAJpg + ".jpg"}; len(keys) != 2 || keys[0] != want[0] || keys[1] != want[1] {
			t.Fatalf("stored keys %q, want %q", keys, want)
		}
		if phase == "1" {
			return // the harness reloads the page now
		}
	}

	// After the reload: a new Go runtime, a new blobFs, the same IndexedDB.
	a := bootBlobs(t, acctA)
	wantBlob(t, shaA, "", blobA)
	wantBlob(t, shaAJpg, "", blobAJpg) // found through afero.Glob's directory listing
	wantBlob(t, shaAJpg, "jpg", blobAJpg)

	// Another account on this browser opens its own database.
	bootBlobs(t, acctB)
	if _, err := openBlobFile(shaA, ""); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("account b opened a's blob: err %v", err)
	}

	// DeleteBlob removes one; a second remove says it is gone.
	fs = a
	if err := fs.Remove(config.BlossomPath + shaAJpg + ".jpg"); err != nil {
		t.Fatal(err)
	}
	if err := fs.Remove(config.BlossomPath + shaAJpg + ".jpg"); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("second remove: err %v, want not exist", err)
	}

	// Sign-out deletes the database while this page still holds it open
	// (vault.js forgetThisBrowser): the delete must not be blocked.
	if got := deleteIDB(t, storeName(acctA, "db/blobs")); got != "" {
		t.Fatalf("sign-out delete: %s", got)
	}
	bootBlobs(t, acctA)
	if _, err := openBlobFile(shaA, ""); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("blob still served after sign-out: err %v", err)
	}
	for _, acct := range []string{acctA, acctB} {
		deleteIDB(t, storeName(acct, "db/blobs"))
	}
}

// bootBlobs is havenStart's part: newRootFs, then MkdirAll opens the database.
func bootBlobs(t *testing.T, account string) afero.Fs {
	t.Helper()
	storePrefix = account
	fs = newRootFs()
	if err := fs.MkdirAll(config.BlossomPath, 0o755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	return fs
}

// storeBlob does what init.go's StoreBlob hook does: a temp file, renamed into place.
func storeBlob(t *testing.T, sha string, body []byte) {
	t.Helper()
	final := config.BlossomPath + sha
	file, err := fs.Create(final + ".tmp")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.Copy(file, bytes.NewReader(body)); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	if err := fs.Rename(final+".tmp", final); err != nil {
		t.Fatal(err)
	}
}

func wantBlob(t *testing.T, sha, ext string, want []byte) {
	t.Helper()
	f, err := openBlobFile(sha, ext)
	if err != nil {
		t.Fatalf("openBlobFile(%s, %q): %v", sha[:4], ext, err)
	}
	defer f.Close()
	got, err := io.ReadAll(f)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("openBlobFile(%s, %q) = %q, want %q", sha[:4], ext, got, want)
	}
}

// deleteIDB deletes a database and reports "" or why it didn't ("blocked",
// "error"). A blocked delete is reported at once instead of waited on.
func deleteIDB(t *testing.T, name string) string {
	t.Helper()
	done := make(chan string, 1)
	req := js.Global().Get("indexedDB").Call("deleteDatabase", name)
	var cbs []js.Func
	for ev, outcome := range map[string]string{"onsuccess": "", "onerror": "error", "onblocked": "blocked"} {
		f := js.FuncOf(func(js.Value, []js.Value) any {
			select {
			case done <- outcome:
			default:
			}
			return nil
		})
		cbs = append(cbs, f)
		req.Set(ev, f)
	}
	outcome := <-done
	for _, f := range cbs {
		f.Release()
	}
	return outcome
}
