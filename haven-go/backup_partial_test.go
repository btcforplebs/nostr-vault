package main

import (
	"archive/zip"
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/nbd-wtf/go-nostr"
)

// failingStore is a store whose reads fail part way through a backup.
type failingStore struct{ DBBackend }

func (failingStore) QueryEvents(context.Context, nostr.Filter) (chan *nostr.Event, error) {
	return nil, errors.New("disk read failed")
}

// A backup cut short never leaves a file that looks like a real backup, and
// never replaces the last good one at that path; a finished one is a
// readable zip with no .partial left beside it.
func TestExportToZipNeverLeavesAHalfBackup(t *testing.T) {
	good := newTestBackend(t, "good")
	if err := good.Init(); err != nil {
		t.Fatal(err)
	}
	defer good.Close()
	sk := nostr.GeneratePrivateKey()
	ev := nostr.Event{Kind: 1, CreatedAt: nostr.Now(), Tags: nostr.Tags{}, Content: "kept"}
	ev.Sign(sk)
	if err := good.SaveEvent(context.Background(), &ev); err != nil {
		t.Fatal(err)
	}
	prev := dbs
	t.Cleanup(func() { dbs = prev })

	path := filepath.Join(t.TempDir(), "nostrvault-backup.zip")
	if err := os.WriteFile(path, []byte("last good backup"), 0o600); err != nil {
		t.Fatal(err)
	}

	dbs = map[string]DBBackend{"outbox": good, "inbox": failingStore{good}}
	if err := exportToZip(context.Background(), path); err == nil {
		t.Fatal("export with a failing store: want an error")
	}
	if b, _ := os.ReadFile(path); string(b) != "last good backup" {
		t.Fatalf("a failed export replaced the last good backup (now %d bytes)", len(b))
	}
	if _, err := os.Stat(path + partialSuffix); !os.IsNotExist(err) {
		t.Fatalf("a failed export left %s behind (%v)", path+partialSuffix, err)
	}

	dbs = map[string]DBBackend{"outbox": good}
	if err := exportToZip(context.Background(), path); err != nil {
		t.Fatal(err)
	}
	zr, err := zip.OpenReader(path)
	if err != nil {
		t.Fatalf("finished backup isn't a zip: %v", err)
	}
	zr.Close()
	if _, err := os.Stat(path + partialSuffix); !os.IsNotExist(err) {
		t.Fatal("a finished export left its .partial behind")
	}
}
