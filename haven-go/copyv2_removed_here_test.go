package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
)

// The app's "Delete from this device" (Android D3) writes removed_here.json in
// the relay data folder; the copy v2 catch-up must not fetch those files back
// from the Mac, for any account's record, while others still come.
func TestCopySyncFileSkipsRemovedHere(t *testing.T) {
	blobWriteDir(t)
	root := t.TempDir()
	prevWD, _ := os.Getwd()
	if err := os.Chdir(root); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(prevWD) })
	t.Cleanup(func() { copyRemovedHere.set = nil })

	removedData, keptData := []byte("removed here"), []byte("still wanted")
	removedSum, keptSum := sha256.Sum256(removedData), sha256.Sum256(keptData)
	removed, kept := hex.EncodeToString(removedSum[:]), hex.EncodeToString(keptSum[:])

	var asked atomic.Int32
	mac := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		asked.Add(1)
		switch strings.TrimPrefix(r.URL.Path, "/copy/v2/sync/file/") {
		case removed:
			_, _ = w.Write(removedData)
		case kept:
			_, _ = w.Write(keptData)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer mac.Close()
	c := &copyClient{base: mac.URL, http: mac.Client()}

	owner, other := strings.Repeat("a", 64), strings.Repeat("b", 64)
	// Listed under the owner, upper-cased: the match ignores case and account.
	list := `{"byAccount":{"` + owner + `":["` + strings.ToUpper(removed) + `"]}}`
	if err := os.WriteFile(copyRemovedHereFile, []byte(list), 0o600); err != nil {
		t.Fatal(err)
	}

	got, err := c.syncFile(context.Background(), copyFile{SHA256: removed, Pubkey: other, CreatedAt: 1}, nil)
	if err != nil || got || asked.Load() != 0 || copyBlobFile(removed) != "" {
		t.Fatalf("removed file: got=%v err=%v asked=%d file=%q, want skipped with no request", got, err, asked.Load(), copyBlobFile(removed))
	}
	got, err = c.syncFile(context.Background(), copyFile{SHA256: kept, Pubkey: owner, CreatedAt: 1}, nil)
	if err != nil || !got || copyBlobFile(kept) == "" {
		t.Fatalf("other file: got=%v err=%v file=%q, want stored", got, err, copyBlobFile(kept))
	}

	// A half-written list keeps the last one read.
	if err := os.WriteFile(copyRemovedHereFile, []byte(`{"byAcc`), 0o600); err != nil {
		t.Fatal(err)
	}
	if !copyIsRemovedHere(removed) {
		t.Fatal("an unreadable list let a removed file back in")
	}

	// Save to Vault took it off: the catch-up may bring it again.
	if err := os.WriteFile(copyRemovedHereFile, []byte(`{"byAccount":{}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err = c.syncFile(context.Background(), copyFile{SHA256: removed, Pubkey: owner, CreatedAt: 1}, nil)
	if err != nil || !got {
		t.Fatalf("after Save to Vault: got=%v err=%v, want stored", got, err)
	}
}
