//go:build !wasm

package main

import (
	"context"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	badgerdb "github.com/dgraph-io/badger/v4"
	"github.com/nbd-wtf/go-nostr"
)

// tidyFixture builds a phone-sized store with more value-log files than the
// tidy allows (one per open that wrote a big value), some events deleted, and
// returns its path with the ids still stored.
func tidyFixture(t *testing.T, opens int) (string, map[string]bool) {
	t.Helper()
	old := badgerTidyMaxVlogs
	badgerTidyMaxVlogs = 8
	t.Cleanup(func() { badgerTidyMaxVlogs = old })

	dir := filepath.Join(t.TempDir(), "inbox")
	sk := nostr.GeneratePrivateKey()
	kept := map[string]bool{}
	now := time.Now().Unix()
	big := strings.Repeat("x", 4<<10) // over the 1 KB value threshold: value log
	for i := range opens {
		s := newBadgerStoreFor(dir, "ios")
		if err := s.BadgerBackend.Init(); err != nil { // no tidy while building
			t.Fatal(err)
		}
		a := signedAt(t, sk, 1, big+"a", now-int64(2*i))
		b := signedAt(t, sk, 1, big+"b", now-int64(2*i+1))
		for _, ev := range []*nostr.Event{a, b} {
			if err := s.SaveEvent(context.Background(), ev); err != nil {
				t.Fatal(err)
			}
		}
		if err := s.DeleteEvent(context.Background(), b); err != nil {
			t.Fatal(err)
		}
		kept[a.ID] = true
		s.Close()
	}
	return dir, kept
}

func storedIDs(t *testing.T, dir string) map[string]bool {
	t.Helper()
	s := newBadgerStoreFor(dir, "ios")
	if err := s.BadgerBackend.Init(); err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	ch, err := s.QueryEvents(context.Background(), nostr.Filter{Kinds: []int{1}, Limit: 1000})
	if err != nil {
		t.Fatal(err)
	}
	ids := map[string]bool{}
	for ev := range ch {
		ids[ev.ID] = true
	}
	return ids
}

func vlogCount(t *testing.T, dir string) int {
	t.Helper()
	n, _, err := dirFiles(dir)
	if err != nil {
		t.Fatal(err)
	}
	return n
}

func dirListing(t *testing.T, dir string) []string {
	t.Helper()
	var out []string
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		info, _ := e.Info()
		out = append(out, e.Name()+":"+info.ModTime().String())
	}
	sort.Strings(out)
	return out
}

func sameIDs(a, b map[string]bool) bool {
	if len(a) != len(b) {
		return false
	}
	for id := range a {
		if !b[id] {
			return false
		}
	}
	return true
}

// A store with too many value-log files opens tidied: the same events,
// deleted ones still gone, a handful of files.
func TestTidyKeepsEveryEventAndDropsTheFiles(t *testing.T) {
	dir, kept := tidyFixture(t, 20)
	if got := storedIDs(t, dir); !sameIDs(got, kept) {
		t.Fatalf("fixture: %d stored, want %d", len(got), len(kept))
	}
	before := vlogCount(t, dir)
	if before <= badgerTidyMaxVlogs {
		t.Fatalf("fixture has %d value-log files, want over %d", before, badgerTidyMaxVlogs)
	}

	s := newBadgerStoreFor(dir, "ios")
	if err := s.Init(); err != nil { // tidies, then opens
		t.Fatal(err)
	}
	s.Close()

	after := vlogCount(t, dir)
	if after >= before || after > 4 {
		t.Fatalf("value-log files %d -> %d", before, after)
	}
	if got := storedIDs(t, dir); !sameIDs(got, kept) {
		t.Fatalf("after tidy: %d stored, want %d", len(got), len(kept))
	}
	for _, suffix := range []string{tidyNewSuffix, tidyOldSuffix} {
		if _, err := os.Stat(dir + suffix); !os.IsNotExist(err) {
			t.Fatalf("%s left behind", suffix)
		}
	}
}

// A copy that doesn't match keeps the old store, untouched.
func TestTidyMismatchKeepsTheOldStore(t *testing.T) {
	dir, kept := tidyFixture(t, 20)
	tidyTestAfterCopy = func(db *badgerdb.DB) {
		// Drop one event from the copy.
		db.Update(func(txn *badgerdb.Txn) error {
			it := txn.NewIterator(badgerdb.IteratorOptions{Prefix: []byte{0}})
			defer it.Close()
			it.Rewind()
			if it.Valid() {
				return txn.Delete(it.Item().KeyCopy(nil))
			}
			return nil
		})
	}
	t.Cleanup(func() { tidyTestAfterCopy = nil })

	before := dirListing(t, dir)
	s := newBadgerStoreFor(dir, "ios")
	res, err := tidyBadgerDir(dir, s.BadgerOptionsModifier)
	if err == nil || res.Tidied {
		t.Fatalf("spoiled copy swapped in: %+v %v", res, err)
	}
	if res.KeysBefore != res.KeysAfter+1 {
		t.Fatalf("keys %d -> %d, want one fewer", res.KeysBefore, res.KeysAfter)
	}
	if _, err := os.Stat(dir + tidyNewSuffix); !os.IsNotExist(err) {
		t.Fatal("spoiled copy left behind")
	}
	// The old store opened once to be read (Badger adds a value-log file on
	// open, removed again next open if empty), so compare the events.
	if got := storedIDs(t, dir); !sameIDs(got, kept) {
		t.Fatalf("old store lost events: %d, want %d (before: %d files)", len(got), len(kept), len(before))
	}
}

// Few files: nothing happens.
func TestTidySkipsATidyStore(t *testing.T) {
	dir, _ := tidyFixture(t, 3)
	before := dirListing(t, dir)
	s := newBadgerStoreFor(dir, "ios")
	res, err := tidyBadgerDir(dir, s.BadgerOptionsModifier)
	if err != nil || res.Tidied || res.SkippedBecause != "few files" {
		t.Fatalf("%+v %v", res, err)
	}
	if after := dirListing(t, dir); strings.Join(after, ",") != strings.Join(before, ",") {
		t.Fatal("a tidy store was touched")
	}
}

// A stop halfway through a swap is finished or undone on the next open.
func TestTidyRecoversAStoppedSwap(t *testing.T) {
	mk := func(t *testing.T, dir, name string) {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, name), nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	has := func(dir, name string) bool {
		_, err := os.Stat(filepath.Join(dir, name))
		return err == nil
	}
	base := t.TempDir()

	// Stopped after the old went aside, before the copy came in: old back.
	p := filepath.Join(base, "a")
	mk(t, p+tidyOldSuffix, "old")
	mk(t, p+tidyNewSuffix, "new")
	if err := recoverTidy(p); err != nil {
		t.Fatal(err)
	}
	if !has(p, "old") || has(p+tidyNewSuffix, "new") || has(p+tidyOldSuffix, "old") {
		t.Fatal("old store not put back")
	}

	// Stopped after the copy came in, before the old was removed: old goes.
	p = filepath.Join(base, "b")
	mk(t, p, "new")
	mk(t, p+tidyOldSuffix, "old")
	if err := recoverTidy(p); err != nil {
		t.Fatal(err)
	}
	if !has(p, "new") || has(p+tidyOldSuffix, "old") {
		t.Fatal("finished swap not cleaned")
	}

	// Stopped while copying: the half copy goes, the store stays.
	p = filepath.Join(base, "c")
	mk(t, p, "old")
	mk(t, p+tidyNewSuffix, "half")
	if err := recoverTidy(p); err != nil {
		t.Fatal(err)
	}
	if !has(p, "old") || has(p+tidyNewSuffix, "half") {
		t.Fatal("half copy not removed")
	}
}
