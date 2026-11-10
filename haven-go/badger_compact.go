//go:build !wasm

package main

import (
	"errors"

	badgerdb "github.com/dgraph-io/badger/v4"
)

// badgerCompactMaxGC bounds the value-log passes of one Compact: each pass
// rewrites at most one value-log file.
const badgerCompactMaxGC = 64

// badgerFlushMarker: a key no store uses (eventstore's prefixes are single
// bytes 0-8 and 255), written and dropped again only to flush the memtables.
var badgerFlushMarker = []byte("\xf0haven-compact-flush")

// Compact gives disk back after deletes. Badger only marks a deleted event:
// the marks sit in the memtable, the deleted keys stay in the tables until a
// compaction meets their marks, and the values stay in the value log until
// that file is rewritten, so a store that only prunes never shrinks.
//
// First the memtables are flushed, so this round's delete marks reach the
// tables: Badger has no flush call of its own, but DropPrefix flushes every
// memtable before it drops, so a marker key is written and dropped. Badger
// refuses writes while it does that, so it runs under hold. Then Flatten
// pushes every table through a compaction, which drops the deleted keys
// and counts what each value-log file holds for nothing, and the GC passes
// rewrite the files that are mostly garbage.
func (s *badgerStore) Compact(hold func(step func() error) error) error {
	err := hold(func() error {
		if err := s.DB.Update(func(txn *badgerdb.Txn) error { return txn.Set(badgerFlushMarker, nil) }); err != nil {
			return err
		}
		return s.DB.DropPrefix(badgerFlushMarker)
	})
	if err != nil {
		return err
	}
	if err := s.DB.Flatten(2); err != nil {
		return err
	}
	for range badgerCompactMaxGC {
		err := s.DB.RunValueLogGC(0.5)
		if errors.Is(err, badgerdb.ErrNoRewrite) {
			return nil
		}
		if err != nil {
			return err
		}
	}
	return nil
}
