//go:build !wasm

package main

import (
	"context"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"strconv"
	"strings"
	"sync"

	badgerdb "github.com/dgraph-io/badger/v4"
	"github.com/fiatjaf/eventstore"
	"github.com/fiatjaf/eventstore/badger"
	"github.com/nbd-wtf/go-nostr"
)

// Badger refuses any one transaction over 15% of the memtable: 26,214 entries
// on the Mac (16 MiB memtable) and 13,107 on a phone (8 MiB), or that many
// bytes / 96. eventstore writes an event, its 6 base index keys and one key
// per indexable tag in a single transaction, and a replace also deletes every
// older copy's keys in that same transaction. So a follow list of ~7,000
// people saves on its own but can't replace an older copy of itself on a
// phone, and a big enough list can't save at all: "Txn is too big to fit into
// one request" (event 08c2d8f1, 7,136 tags, 2026-11-04). Raising the memtable
// costs RAM on every store, and lowering it later bricks the store (see
// init_badger.go), so instead a write Badger refuses for size is redone in
// parts. Every write that fits still takes eventstore's own single-transaction
// path, untouched.
//
// The parts: the raw event and its base index keys in one transaction (the
// tag indexes skipped through SkipIndexingTag), then the tag index keys in
// WriteBatches, which split themselves to fit. A delete runs the other way
// round, tag keys first. If the process dies in between, the event is stored
// but unfindable by tag until it is deleted or replaced; it is never half
// deleted into an event whose raw copy is gone while its keys remain.

// badgerStore is the eventstore Badger backend with that fallback.
type badgerStore struct {
	*badger.BadgerBackend

	// splitting holds the ids being written in parts, whose tag indexes
	// eventstore must skip (skipTag).
	splitting sync.Map
	// splitMu serialises the part-by-part paths, which aren't one transaction.
	splitMu sync.Mutex
}

func (s *badgerStore) skipTag(evt *nostr.Event, _ string, _ string) bool {
	_, ok := s.splitting.Load(evt.ID)
	return ok
}

func isTxnTooBig(err error) bool { return errors.Is(err, badgerdb.ErrTxnTooBig) }

func (s *badgerStore) SaveEvent(ctx context.Context, evt *nostr.Event) error {
	err := s.BadgerBackend.SaveEvent(ctx, evt)
	if !isTxnTooBig(err) {
		return err
	}
	s.splitMu.Lock()
	defer s.splitMu.Unlock()
	return s.saveSplit(ctx, evt)
}

func (s *badgerStore) DeleteEvent(ctx context.Context, evt *nostr.Event) error {
	err := s.BadgerBackend.DeleteEvent(ctx, evt)
	if !isTxnTooBig(err) {
		return err
	}
	s.splitMu.Lock()
	defer s.splitMu.Unlock()
	return s.deleteSplit(ctx, evt)
}

func (s *badgerStore) ReplaceEvent(ctx context.Context, evt *nostr.Event) error {
	err := s.BadgerBackend.ReplaceEvent(ctx, evt)
	if !isTxnTooBig(err) {
		return err
	}
	s.splitMu.Lock()
	defer s.splitMu.Unlock()
	return s.replaceSplit(ctx, evt)
}

// saveSplit: the raw event and base keys first (that transaction also does
// eventstore's duplicate check), then the tag keys.
func (s *badgerStore) saveSplit(ctx context.Context, evt *nostr.Event) error {
	s.splitting.Store(evt.ID, struct{}{})
	err := s.BadgerBackend.SaveEvent(ctx, evt)
	s.splitting.Delete(evt.ID)
	if err != nil {
		return err
	}
	serial, ok := s.serialOf(evt)
	if !ok {
		return errors.New("badger split save: event not found after its own save")
	}
	return s.writeTagKeys(evt, serial, false)
}

// deleteSplit: the tag keys first, then the raw event and base keys.
func (s *badgerStore) deleteSplit(ctx context.Context, evt *nostr.Event) error {
	serial, ok := s.serialOf(evt)
	if !ok {
		return nil // not stored
	}
	if err := s.writeTagKeys(evt, serial, true); err != nil {
		return err
	}
	s.splitting.Store(evt.ID, struct{}{})
	defer s.splitting.Delete(evt.ID)
	return s.BadgerBackend.DeleteEvent(ctx, evt)
}

// replaceSplit keeps eventstore's ReplaceEvent rules (replace.go): if any
// stored copy is not older, store nothing; otherwise store evt and drop the
// older copies. The new copy is stored before the old ones go, so a failure
// part way leaves an extra old copy (queries for a replaceable kind return
// the newest), never no copy at all.
func (s *badgerStore) replaceSplit(ctx context.Context, evt *nostr.Event) error {
	previous, err := s.storedCopies(ctx, evt)
	if err != nil {
		return err
	}
	for _, p := range previous {
		if !isOlderCopy(p, evt) {
			return nil
		}
	}
	if err := s.BadgerBackend.SaveEvent(ctx, evt); isTxnTooBig(err) {
		err = s.saveSplit(ctx, evt)
		if err != nil && !errors.Is(err, eventstore.ErrDupEvent) {
			return err
		}
	} else if err != nil && !errors.Is(err, eventstore.ErrDupEvent) {
		return err
	}
	for _, p := range previous {
		if err := s.BadgerBackend.DeleteEvent(ctx, p); isTxnTooBig(err) {
			if err := s.deleteSplit(ctx, p); err != nil {
				return err
			}
		} else if err != nil {
			return err
		}
	}
	return nil
}

// replacePadKind is added to storedCopies' kinds so the query isn't capped at
// one result for a replaceable kind (nostr.GetTheoreticalLimit). Ephemeral,
// so no store keeps it.
const replacePadKind = 29999

// storedCopies: the stored copies of evt's replaceable or addressable slot
// (eventstore's replace looks at up to 10).
func (s *badgerStore) storedCopies(ctx context.Context, evt *nostr.Event) ([]*nostr.Event, error) {
	f := nostr.Filter{Authors: []string{evt.PubKey}, Kinds: []int{evt.Kind, replacePadKind}, Limit: 50}
	if nostr.IsAddressableKind(evt.Kind) {
		f.Tags = nostr.TagMap{"d": []string{evt.Tags.GetD()}}
	}
	ch, err := s.BadgerBackend.QueryEvents(ctx, f)
	if err != nil {
		return nil, err
	}
	var out []*nostr.Event
	for ev := range ch {
		if ev.Kind != evt.Kind || ev.PubKey != evt.PubKey {
			continue
		}
		if nostr.IsAddressableKind(evt.Kind) && ev.Tags.GetD() != evt.Tags.GetD() {
			continue
		}
		out = append(out, ev)
	}
	return out, nil
}

// isOlderCopy is eventstore's internal.IsOlder.
func isOlderCopy(previous, next *nostr.Event) bool {
	return previous.CreatedAt < next.CreatedAt ||
		(previous.CreatedAt == next.CreatedAt && previous.ID > next.ID)
}

// serialOf finds evt's 4-byte serial through its id index key
// (2 | id[:8] | serial), as eventstore's delete does.
func (s *badgerStore) serialOf(evt *nostr.Event) ([]byte, bool) {
	id8, err := hex.DecodeString(evt.ID[0 : 8*2])
	if err != nil {
		return nil, false
	}
	prefix := append([]byte{badgerIndexIDPrefix}, id8...)
	var serial []byte
	_ = s.View(func(txn *badgerdb.Txn) error {
		it := txn.NewIterator(badgerdb.IteratorOptions{PrefetchValues: false})
		defer it.Close()
		it.Seek(prefix)
		if it.ValidForPrefix(prefix) {
			serial = append([]byte(nil), it.Item().Key()[1+8:]...)
		}
		return nil
	})
	return serial, len(serial) == 4
}

// writeTagKeys sets (or deletes) evt's tag index keys in WriteBatches.
func (s *badgerStore) writeTagKeys(evt *nostr.Event, serial []byte, del bool) error {
	wb := s.NewWriteBatch()
	defer wb.Cancel()
	for _, k := range badgerTagIndexKeys(evt, serial) {
		var err error
		if del {
			err = wb.Delete(k)
		} else {
			err = wb.Set(k, nil)
		}
		if err != nil {
			return err
		}
	}
	return wb.Flush()
}

// eventstore v0.17.15 badger key prefixes (badger/lib.go).
const (
	badgerIndexIDPrefix      byte = 2
	badgerIndexTagPrefix     byte = 6
	badgerIndexTag32Prefix   byte = 7
	badgerIndexTagAddrPrefix byte = 8
)

// badgerTagIndexKeys is the tag part of eventstore's getIndexKeysForEvent
// (badger/helpers.go, v0.17.15), with no IndexLongerTag and no
// SkipIndexingTag (newBadgerStoreFor sets neither for a normal write), byte
// for byte. TestBadgerTagIndexKeysMatchEventstore checks it against the keys
// eventstore itself writes; bump that test with any eventstore upgrade.
func badgerTagIndexKeys(evt *nostr.Event, serial []byte) [][]byte {
	var keys [][]byte
	seen := make(map[string]struct{})
	for _, tag := range evt.Tags {
		if len(tag) < 2 || len(tag[0]) != 1 || len(tag[1]) == 0 || len(tag[1]) > 100 {
			continue
		}
		// eventstore indexes the first copy of a (name, value) only.
		dup := tag[0] + "\x00" + tag[1]
		if _, ok := seen[dup]; ok {
			continue
		}
		seen[dup] = struct{}{}

		k, offset := badgerTagIndexPrefix(tag[0], tag[1])
		binary.BigEndian.PutUint32(k[offset:], uint32(evt.CreatedAt))
		copy(k[offset+4:], serial)
		keys = append(keys, k)
	}
	return keys
}

// badgerTagIndexPrefix is eventstore's getTagIndexPrefix, including its "a"
// key whose letter byte the kind then overwrites.
func badgerTagIndexPrefix(tagName string, tagValue string) ([]byte, int) {
	var k []byte
	var offset int

	letterPrefix := byte(int(tagName[0]) % 256)

	if kind, pkb, d := badgerAddrTagElements(tagValue); len(pkb) == 32 {
		k = make([]byte, 1+1+2+8+len(d)+4+4)
		k[0] = badgerIndexTagAddrPrefix
		k[1] = letterPrefix
		binary.BigEndian.PutUint16(k[1:], kind)
		copy(k[1+1+2:], pkb[0:8])
		copy(k[1+1+2+8:], d)
		offset = 1 + 1 + 2 + 8 + len(d)
	} else if vb, _ := hex.DecodeString(tagValue); len(vb) == 32 {
		k = make([]byte, 1+1+8+4+4)
		k[0] = badgerIndexTag32Prefix
		k[1] = letterPrefix
		copy(k[2:], vb[0:8])
		offset = 1 + 1 + 8
	} else {
		k = make([]byte, 1+1+len(tagValue)+4+4)
		k[0] = badgerIndexTagPrefix
		k[1] = letterPrefix
		copy(k[2:], tagValue)
		offset = 1 + 1 + len(tagValue)
	}
	return k, offset
}

func badgerAddrTagElements(tagValue string) (kind uint16, pkb []byte, d string) {
	spl := strings.Split(tagValue, ":")
	if len(spl) == 3 {
		if pkb, _ := hex.DecodeString(spl[1]); len(pkb) == 32 {
			if kind, err := strconv.ParseUint(spl[0], 10, 16); err == nil {
				return uint16(kind), pkb, spl[2]
			}
		}
	}
	return 0, nil, ""
}
