package main

import (
	"archive/zip"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

func signedNote(t *testing.T, sk string, createdAt time.Time, content string) *nostr.Event {
	t.Helper()
	ev := &nostr.Event{Kind: 1, CreatedAt: nostr.Timestamp(createdAt.Unix()), Tags: nostr.Tags{}, Content: content}
	if err := ev.Sign(sk); err != nil {
		t.Fatal(err)
	}
	return ev
}

func writeBackupZip(t *testing.T, events ...*nostr.Event) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "backup.zip")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	zw := zip.NewWriter(f)
	w, err := zw.Create("outbox.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	for _, ev := range events {
		fmt.Fprintln(w, ev)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	f.Close()
	return path
}

// A backup file is untrusted: importDB keeps only events whose id and
// signature check out and that are not dated in the future (Tron, PR 1254:
// a zero-sig owner kind 3 dated 2100 used to land and set the Web of Trust).
func TestImportDBSkipsForgedAndFutureEvents(t *testing.T) {
	db := newTestBackend(t, "import")
	if err := db.Init(); err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	ctx := context.Background()
	now := time.Now()
	sk := nostr.GeneratePrivateKey()

	good := signedNote(t, sk, now.Add(-time.Hour), "kept")

	zeroSig := signedNote(t, sk, now.Add(-time.Hour), "zero sig")
	zeroSig.Sig = strings.Repeat("0", 128)

	altered := signedNote(t, sk, now.Add(-time.Hour), "original")
	altered.Content = "altered" // id no longer matches

	future := signedNote(t, sk, time.Date(2100, 1, 1, 0, 0, 0, 0, time.UTC), "from 2100")

	var lines strings.Builder
	for _, ev := range []*nostr.Event{good, zeroSig, altered, future} {
		fmt.Fprintln(&lines, ev)
	}
	if err := importDB(ctx, db, strings.NewReader(lines.String())); err != nil {
		t.Fatal(err)
	}

	ch, err := db.QueryEvents(ctx, nostr.Filter{})
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for ev := range ch {
		got = append(got, ev.Content)
	}
	if len(got) != 1 || got[0] != "kept" {
		t.Fatalf("imported %q, want only the valid event", got)
	}
}

func TestImportableAllowsClockSkew(t *testing.T) {
	now := time.Now()
	sk := nostr.GeneratePrivateKey()
	if !importable(signedNote(t, sk, now.Add(time.Hour), "skewed"), now) {
		t.Fatal("an event an hour ahead (clock skew) was refused")
	}
	if importable(signedNote(t, sk, now.Add(48*time.Hour), "ahead"), now) {
		t.Fatal("an event two days ahead was accepted")
	}
}

// Setup only restores the signing-in key's own backup.
func TestZipHasEventBy(t *testing.T) {
	now := time.Now()
	owner := nostr.GeneratePrivateKey()
	ownerPub, _ := nostr.GetPublicKey(owner)
	other := nostr.GeneratePrivateKey()

	theirs := writeBackupZip(t, signedNote(t, other, now, "not yours"))
	if ok, err := zipHasEventBy(theirs, ownerPub); err != nil || ok {
		t.Fatalf("someone else's backup: ok=%v err=%v, want refused", ok, err)
	}

	forged := signedNote(t, owner, now, "forged as owner")
	forged.Sig = strings.Repeat("0", 128)
	if ok, err := zipHasEventBy(writeBackupZip(t, forged), ownerPub); err != nil || ok {
		t.Fatalf("forged owner event: ok=%v err=%v, want refused", ok, err)
	}

	ours := writeBackupZip(t, signedNote(t, other, now, "a reply"), signedNote(t, owner, now, "mine"))
	if ok, err := zipHasEventBy(ours, ownerPub); err != nil || !ok {
		t.Fatalf("owner's backup: ok=%v err=%v, want accepted", ok, err)
	}
}
