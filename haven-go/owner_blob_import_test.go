//go:build !(js && wasm)

package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"

	"github.com/nbd-wtf/go-nostr"
)

func ownerBlobFile(t *testing.T, data []byte) (string, string) {
	t.Helper()
	sum := sha256.Sum256(data)
	path := filepath.Join(t.TempDir(), "download.blob")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	return path, hex.EncodeToString(sum[:])
}

func ownerBlobRecords(t *testing.T, author, sha string) []*nostr.Event {
	t.Helper()
	ch, err := blossomDB.QueryEvents(context.Background(), nostr.Filter{Authors: []string{author}, Kinds: []int{24242}, Tags: nostr.TagMap{"x": []string{sha}}})
	if err != nil {
		t.Fatal(err)
	}
	var out []*nostr.Event
	for ev := range ch {
		out = append(out, ev)
	}
	return out
}

// A keyless vault's app stores the owner's media with no signature: the file
// under its hash and one owner blob record in Keep's shape, once.
func TestImportOwnerBlobStoresFileAndRecord(t *testing.T) {
	owner, _ := nostr.GetPublicKey(nostr.GeneratePrivateKey())
	openCopyVault(t, owner)
	data := []byte("owner photo bytes")
	path, sha := ownerBlobFile(t, data)

	if err := importOwnerBlob(context.Background(), path, sha, "image/jpeg"); err != nil {
		t.Fatalf("import: %v", err)
	}
	got, err := os.ReadFile(copyBlobFile(sha))
	if err != nil || string(got) != string(data) {
		t.Fatalf("stored file = %q, %v", got, err)
	}
	recs := ownerBlobRecords(t, owner, sha)
	if len(recs) != 1 {
		t.Fatalf("records = %d, want 1", len(recs))
	}
	tags := recs[0].Tags
	if len(tags) != 3 || tags[0][1] != sha || tags[1][1] != "image/jpeg" || tags[2][1] != "17" {
		t.Fatalf("record tags = %v", tags)
	}
	// Again: no second record, still fine.
	if err := importOwnerBlob(context.Background(), path, sha, "image/jpeg"); err != nil {
		t.Fatalf("second import: %v", err)
	}
	if n := len(ownerBlobRecords(t, owner, sha)); n != 1 {
		t.Fatalf("records after second import = %d, want 1", n)
	}
}

// What it refuses: a file that does not hash to the name given, a type a
// browser would run, a bad hash, and a vault whose store is not open.
func TestImportOwnerBlobRefuses(t *testing.T) {
	owner, _ := nostr.GetPublicKey(nostr.GeneratePrivateKey())
	openCopyVault(t, owner)
	path, sha := ownerBlobFile(t, []byte("real bytes"))
	_, otherSha := ownerBlobFile(t, []byte("other bytes"))

	if err := importOwnerBlob(context.Background(), path, otherSha, "image/jpeg"); err == nil {
		t.Fatal("a file under someone else's hash was stored")
	}
	if copyBlobFile(otherSha) != "" || len(ownerBlobRecords(t, owner, otherSha)) != 0 {
		t.Fatal("a mismatched file left a blob or record behind")
	}
	if err := importOwnerBlob(context.Background(), path, sha, "text/html"); err == nil {
		t.Fatal("an html blob was stored")
	}
	if copyBlobFile(sha) != "" {
		t.Fatal("a refused html blob left its file behind")
	}
	if err := importOwnerBlob(context.Background(), path, "abc", "image/jpeg"); err == nil {
		t.Fatal("a bad hash was accepted")
	}
	blossomDB = nil
	if err := importOwnerBlob(context.Background(), path, sha, "image/jpeg"); err == nil {
		t.Fatal("stored with no vault open")
	}
}
