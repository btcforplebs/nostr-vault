//go:build wasm

package main

import (
	"context"
	"encoding/binary"
	"fmt"
	"math"
	"slices"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/fiatjaf/eventstore"
	"github.com/nbd-wtf/go-nostr"
)

// The wasm build cannot use LMDB (cgo) or Badger (mmap is "not implemented
// on js"), so every database falls back to this in-memory store until a
// browser-persistent eventstore (OPFS/IndexedDB) replaces it. Nothing here
// survives a page reload.
//
// eventstore/slicestore is not used as-is: it locks only ReplaceEvent (Save,
// Delete and the query goroutine race each other) and it clamps an
// over-limit filter down to MaxLimit. This store keeps Badger's semantics
// instead, so routes answer exactly as they do on the phones.
const fallbackBackendName = "the in-memory store"

func fallbackBackend(path string) DBBackend { return newMemBackend(path) }

func newMemBackend(string) DBBackend { return &memStore{} }

type memStore struct {
	mu     sync.RWMutex
	events []*nostr.Event // newest first; ties broken by ID descending
	serial atomic.Uint32

	// Same defaults as eventstore/badger (lib.go:60-66).
	MaxLimit           int
	MaxLimitNegentropy int
}

func (m *memStore) Init() error {
	if m.MaxLimit == 0 {
		m.MaxLimit = 1000
	}
	if m.MaxLimitNegentropy == 0 {
		m.MaxLimitNegentropy = 16777216
	}
	return nil
}

func (m *memStore) Close() {}

func (m *memStore) Serial() []byte {
	vb := make([]byte, 5)
	binary.BigEndian.PutUint32(vb[1:], m.serial.Add(1))
	return vb
}

func memCompare(a, b *nostr.Event) int {
	if a.CreatedAt != b.CreatedAt {
		if a.CreatedAt > b.CreatedAt {
			return -1
		}
		return 1
	}
	return strings.Compare(b.ID, a.ID)
}

// limitFor mirrors eventstore/badger/query.go:30-45: an over-MaxLimit or
// absent limit falls through to MaxLimit/4 rather than being clamped.
func (m *memStore) limitFor(ctx context.Context, filter nostr.Filter) int {
	maxLimit := m.MaxLimit
	var limit int
	if eventstore.IsNegentropySession(ctx) {
		maxLimit = m.MaxLimitNegentropy
		limit = maxLimit
	} else {
		limit = maxLimit / 4
	}
	if filter.Limit > 0 && filter.Limit <= maxLimit {
		limit = filter.Limit
	}
	if tlimit := nostr.GetTheoreticalLimit(filter); tlimit >= 0 {
		limit = tlimit
	}
	return limit
}

func (m *memStore) QueryEvents(ctx context.Context, filter nostr.Filter) (chan *nostr.Event, error) {
	ch := make(chan *nostr.Event)
	limit := m.limitFor(ctx, filter)
	if filter.Search != "" || limit == 0 {
		close(ch)
		return ch, nil
	}

	// Collect under the lock, then send without it so a slow reader can't
	// block writers.
	m.mu.RLock()
	results := make([]*nostr.Event, 0, min(limit, len(m.events)))
	for _, evt := range m.events {
		if filter.Until != nil && evt.CreatedAt > *filter.Until {
			continue
		}
		if filter.Since != nil && evt.CreatedAt < *filter.Since {
			break
		}
		if filter.Matches(evt) {
			results = append(results, evt)
			if len(results) == limit {
				break
			}
		}
	}
	m.mu.RUnlock()

	go func() {
		defer close(ch)
		for _, evt := range results {
			select {
			case ch <- evt:
			case <-ctx.Done():
				return
			}
		}
	}()
	return ch, nil
}

func (m *memStore) CountEvents(_ context.Context, filter nostr.Filter) (int64, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	var n int64
	for _, evt := range m.events {
		if filter.Matches(evt) {
			n++
		}
	}
	return n, nil
}

func (m *memStore) saveLocked(evt *nostr.Event) error {
	idx, found := slices.BinarySearchFunc(m.events, evt, memCompare)
	if found {
		return eventstore.ErrDupEvent
	}
	m.events = slices.Insert(m.events, idx, evt)
	return nil
}

func (m *memStore) deleteLocked(evt *nostr.Event) {
	if idx, found := slices.BinarySearchFunc(m.events, evt, memCompare); found {
		m.events = slices.Delete(m.events, idx, idx+1)
	}
}

func (m *memStore) SaveEvent(_ context.Context, evt *nostr.Event) error {
	if evt.CreatedAt > math.MaxUint32 || evt.Kind > math.MaxUint16 {
		return fmt.Errorf("event with values out of expected boundaries")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.saveLocked(evt)
}

func (m *memStore) DeleteEvent(_ context.Context, evt *nostr.Event) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.deleteLocked(evt)
	return nil
}

// ReplaceEvent follows eventstore/badger/replace.go: drop every older version
// of the same kind+author(+d), store this one unless a newer one exists.
func (m *memStore) ReplaceEvent(_ context.Context, evt *nostr.Event) error {
	if evt.CreatedAt > math.MaxUint32 || evt.Kind > math.MaxUint16 {
		return fmt.Errorf("event with values out of expected boundaries")
	}
	filter := nostr.Filter{Kinds: []int{evt.Kind}, Authors: []string{evt.PubKey}}
	if nostr.IsAddressableKind(evt.Kind) {
		filter.Tags = nostr.TagMap{"d": []string{evt.Tags.GetD()}}
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	shouldStore := true
	var older []*nostr.Event
	for _, prev := range m.events {
		if !filter.Matches(prev) {
			continue
		}
		if prev.CreatedAt < evt.CreatedAt || (prev.CreatedAt == evt.CreatedAt && prev.ID > evt.ID) {
			older = append(older, prev)
		} else {
			shouldStore = false
		}
	}
	for _, prev := range older {
		m.deleteLocked(prev)
	}
	if shouldStore {
		if err := m.saveLocked(evt); err != nil && err != eventstore.ErrDupEvent {
			return err
		}
	}
	return nil
}
