//go:build !wasm

package main

import (
	"encoding/binary"
	"encoding/hex"
	"slices"
	"sync"
	"sync/atomic"

	badgerdb "github.com/dgraph-io/badger/v4"
)

// idIndexPrefix is eventstore/badger's id index key prefix (lib.go
// indexIdPrefix); its keys are the prefix, the first 8 bytes of the id, then
// the event's serial (save.go).
const idIndexPrefix byte = 2

// Most events the read loop sees are new, and asking Badger about each one
// costs a read transaction that wakes Badger's watermark goroutine twice:
// about 10 µs of CPU across the four stores, a third of the verify it is
// meant to save. So each store's ids are read once, in the background, into
// a sorted set of their first 8 bytes (key-only, no event decoded), and the
// store is only asked about an id the set holds.
//
// A stale set is safe both ways. An event stored after the set was read is
// missing from it, so it is verified as before. An id the set holds that the
// store no longer has, or another id sharing its first 8 bytes, is looked up
// properly and verified when the store has no exact copy.
type storedIDSet struct {
	ready atomic.Bool
	ids   []uint64 // sorted; written once before ready is set
}

var (
	storedIDSetsMu sync.Mutex
	storedIDSets   = map[*gatedDB]*storedIDSet{}
)

// mayHoldID reports whether this store may hold the id. False until the
// store's set has been read, so a fresh launch verifies as before meanwhile.
func (g *gatedDB) mayHoldID(id string) bool {
	var p [8]byte
	if _, err := hex.Decode(p[:], []byte(id[:16])); err != nil {
		return false
	}
	set := storedIDSetFor(g)
	if set == nil || !set.ready.Load() {
		return false
	}
	_, found := slices.BinarySearch(set.ids, binary.BigEndian.Uint64(p[:]))
	return found
}

// storedIDSetFor returns g's set, starting its read the first time, and
// drops the sets of stores a past relay cycle closed.
func storedIDSetFor(g *gatedDB) *storedIDSet {
	storedIDSetsMu.Lock()
	defer storedIDSetsMu.Unlock()
	if set, ok := storedIDSets[g]; ok {
		return set
	}
	for old := range storedIDSets {
		if old.isClosing() {
			delete(storedIDSets, old)
		}
	}
	if g.isClosing() {
		return nil
	}
	set := &storedIDSet{}
	storedIDSets[g] = set
	go set.read(g)
	return set
}

// read collects the id index's 8-byte prefixes, keys only, inside the gate
// so the store cannot close under it. A store that is not Badger stays
// not-ready: its events are verified as before.
func (s *storedIDSet) read(g *gatedDB) {
	if !g.enter() {
		return
	}
	defer g.leave()
	inner := g.inner
	if lh, ok := inner.(*listHistoryDB); ok {
		inner = lh.DBBackend
	}
	bs, ok := inner.(*badgerStore)
	if !ok || bs.BadgerBackend == nil || bs.DB == nil {
		return
	}
	var ids []uint64
	err := bs.DB.View(func(txn *badgerdb.Txn) error {
		prefix := []byte{idIndexPrefix}
		it := txn.NewIterator(badgerdb.IteratorOptions{PrefetchValues: false, Prefix: prefix})
		defer it.Close()
		for it.Seek(prefix); it.ValidForPrefix(prefix); it.Next() {
			if k := it.Item().Key(); len(k) >= 9 {
				ids = append(ids, binary.BigEndian.Uint64(k[1:9]))
			}
		}
		return nil
	})
	if err != nil {
		return
	}
	slices.Sort(ids)
	s.ids = slices.Compact(ids)
	s.ready.Store(true)
}
