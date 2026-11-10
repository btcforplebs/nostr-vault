//go:build !wasm

package main

import (
	"context"
	"fmt"
	iofs "io/fs"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/fiatjaf/eventstore"
	"github.com/nbd-wtf/go-nostr"
)

// The feed prune deleted old events every round, but Badger gives no disk
// back for a delete on its own, so the feed cache's folder never shrank.

func folderBytes(t *testing.T, dir string) int64 {
	t.Helper()
	var n int64
	err := filepath.WalkDir(dir, func(_ string, d iofs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.IsDir() {
			info, err := d.Info()
			if err != nil {
				return err
			}
			n += info.Size()
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return n
}

func openPhoneFeed(t *testing.T, dir string) *gatedDB {
	t.Helper()
	inner := newBadgerStoreFor(dir, "android")
	if err := inner.Init(); err != nil {
		t.Fatal(err)
	}
	return newGatedDB(inner)
}

func TestFeedPruneThenCompactShrinksTheDisk(t *testing.T) {
	if testing.Short() {
		t.Skip("writes ~80 MB")
	}
	prevCfg, prevFeed := config, feedDB
	t.Cleanup(func() {
		config, feedDB = prevCfg, prevFeed
		feedCompact.Lock()
		feedCompact.last = time.Time{}
		feedCompact.Unlock()
	})
	config.FeedSyncWindowDays = 7
	ctx := context.Background()
	dir := t.TempDir()
	k := newTestKey(t)

	// A cache that has been running a while: a month-old backlog and this
	// week's notes, already on disk (written, closed, opened again).
	db := openPhoneFeed(t, dir)
	old := nostr.Now() - 30*86400
	body := strings.Repeat("old note text ", 110) // ~1.5 KB, past the 1 KB inline threshold
	for i := range 24_000 {
		saveEv(t, db, k.sign(t, nostr.Event{Kind: nostr.KindTextNote, CreatedAt: old - nostr.Timestamp(i), Content: body}))
	}
	var recent []string
	week := nostr.Now() - 3600
	for i := range 500 {
		ev := k.sign(t, nostr.Event{Kind: nostr.KindTextNote, CreatedAt: week - nostr.Timestamp(i), Content: "this week"})
		saveEv(t, db, ev)
		recent = append(recent, ev.ID)
	}
	db.Close()
	db = openPhoneFeed(t, dir)
	t.Cleanup(db.Close)
	feedDB = db
	full := folderBytes(t, dir)

	deleted := 0
	for {
		n := pruneFeed(ctx, eventstore.RelayWrapper{Store: db})
		deleted += n
		if n == 0 {
			break
		}
	}
	if deleted != 24_000 {
		t.Fatalf("prune deleted %d of the 24,000 old notes", deleted)
	}
	pruned := folderBytes(t, dir)
	if pruned < full*9/10 {
		t.Logf("note: the delete alone already gave back %d of %d bytes", full-pruned, full)
	}

	if !compactAfterPrune(db, deleted, time.Now()) {
		t.Fatal("no compaction after a prune that deleted notes")
	}
	compacted := folderBytes(t, dir)
	t.Logf("feed folder: %d bytes full, %d after prune, %d after compaction", full, pruned, compacted)
	if compacted > pruned*6/10 {
		t.Fatalf("compaction left %d of %d bytes: the disk did not shrink", compacted, pruned)
	}
	if n := countIn(t, db, nostr.Filter{IDs: recent}); n != len(recent) {
		t.Fatalf("compaction lost notes it should keep: %d of %d left", n, len(recent))
	}

	// Writes that come in during a compaction wait for the flush instead of
	// failing (Badger refuses writes while it flushes).
	stop := make(chan struct{})
	errs := make(chan error, 1)
	go func() {
		defer close(errs)
		for i := 0; ; i++ {
			select {
			case <-stop:
				return
			default:
			}
			ev := k.sign(t, nostr.Event{Kind: nostr.KindTextNote, CreatedAt: nostr.Now() - 60, Content: fmt.Sprint("during ", i)})
			if err := db.SaveEvent(ctx, &ev); err != nil {
				errs <- err
				return
			}
		}
	}()
	for range 30 {
		if err := db.Compact(); err != nil {
			t.Fatal(err)
		}
	}
	close(stop)
	if err := <-errs; err != nil {
		t.Fatalf("a write during compaction failed: %v", err)
	}

	// Rate-limited: the next round's prune does not rewrite the store again.
	if compactAfterPrune(db, 10, time.Now().Add(time.Hour)) {
		t.Fatal("compacted again an hour later")
	}
	if !compactAfterPrune(db, 10, time.Now().Add(feedCompactEvery)) {
		t.Fatal("not compacted again once feedCompactEvery had passed")
	}
	// Nothing deleted: nothing to give back.
	if compactAfterPrune(db, 0, time.Now().Add(2*feedCompactEvery)) {
		t.Fatal("compacted after a prune that deleted nothing")
	}

	// The store opens again whole.
	db.Close()
	db = openPhoneFeed(t, dir)
	t.Cleanup(db.Close)
	if n := countIn(t, db, nostr.Filter{IDs: recent}); n != len(recent) {
		t.Fatalf("after reopening: %d of %d kept notes", n, len(recent))
	}
	if n := countIn(t, db, nostr.Filter{Until: &old}); n != 0 {
		t.Fatalf("after reopening: %d pruned notes are back", n)
	}
}

// A closing store refuses the compaction instead of running it under a close.
func TestCompactRefusedWhileClosing(t *testing.T) {
	db := openPhoneFeed(t, t.TempDir())
	db.Close()
	if err := db.Compact(); err != errDBClosing {
		t.Fatalf("compact on a closed store: %v, want errDBClosing", err)
	}
}
