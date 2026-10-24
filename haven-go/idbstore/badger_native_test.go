//go:build !js

package idbstore_test

// The same cases on eventstore/badger, the backend Haven runs on the phones.
// This is the reference the browser store has to match.

import (
	"github.com/nbd-wtf/go-nostr"
	"os"
	"path/filepath"
	"testing"

	"github.com/fiatjaf/eventstore"
	"github.com/fiatjaf/eventstore/badger"
)

func badgerAt(t *testing.T) eventstore.Store {
	dir := filepath.Join(t.TempDir(), "badger")
	t.Cleanup(func() { os.RemoveAll(dir) })
	return &badger.BadgerBackend{Path: dir}
}

func TestBadgerCombinations(t *testing.T) { runCombinations(t, badgerAt(t)) }
func TestBadgerLimits(t *testing.T)       { runLimits(t, badgerAt(t)) }
func TestBadgerReplace(t *testing.T)      { runReplace(t, badgerAt(t)) }
func TestBadgerManyAuthors(t *testing.T)  { runManyAuthors(t, badgerAt(t)) }

// Records the badger quirk the browser store deliberately does not copy.
func TestBadgerDuplicateFilterValues(t *testing.T) {
	db := badgerAt(t)
	if err := db.Init(); err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	a1 := mk(t, skA, 1, 10)
	save(t, db, a1)
	got := query(t, db, nostr.Filter{Authors: []string{pub(skA), pub(skA)}, Kinds: []int{1, 1}})
	t.Logf("authors {A,A} x kinds {1,1}: badger returned %d copies of one event", len(got))

	both := mk(t, skC, 1, 22, nostr.Tag{"t", "a"}, nostr.Tag{"t", "b"})
	save(t, db, both)
	got = query(t, db, nostr.Filter{Tags: nostr.TagMap{"t": {"a", "b"}}})
	t.Logf("#t [a,b] on an event tagged a and b: badger returned %d copies", len(got))
}
