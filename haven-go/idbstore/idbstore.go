//go:build js && wasm

package idbstore

import (
	"context"
	"errors"
	"fmt"
	"math"
	"sync/atomic"
	"syscall/js"

	"github.com/fiatjaf/eventstore"
	"github.com/nbd-wtf/go-nostr"
)

const (
	dbVersion   = 1
	eventsStore = "events"

	idxCreatedAt  = "ca"
	idxKind       = "k_ca"
	idxAuthor     = "pk_ca"
	idxAuthorKind = "pk_k_ca"
	idxTag        = "tag"
)

var _ eventstore.Store = (*IDBBackend)(nil)
var _ eventstore.Counter = (*IDBBackend)(nil)

type IDBBackend struct {
	// Name is the IndexedDB database name. One database per Haven relay route.
	Name string

	MaxLimit           int
	MaxLimitNegentropy int

	db              js.Value
	onVersionChange js.Func
	serial          atomic.Uint32
}

// VersionChangeEvent is dispatched on the global scope when another tab opens
// this database at a newer version (a build that bumped dbVersion). The
// database is closed first, so that tab's open is not left blocked behind this
// one; Haven here can no longer read or write and the page should reload.
const VersionChangeEvent = "idbstore-versionchange"

func (b *IDBBackend) Init() error {
	if b.Name == "" {
		return errors.New("idbstore: Name is required")
	}
	// Same defaults as eventstore/badger (lib.go Init).
	if b.MaxLimit != 0 {
		b.MaxLimitNegentropy = b.MaxLimit
	} else {
		b.MaxLimit = 1000
		if b.MaxLimitNegentropy == 0 {
			b.MaxLimitNegentropy = 16777216
		}
	}

	idb := js.Global().Get("indexedDB")
	if idb.IsUndefined() || idb.IsNull() {
		return errors.New("idbstore: indexedDB is not available in this context")
	}
	req, err := jsCall(idb, "open", b.Name, dbVersion)
	if err != nil {
		return err
	}
	onUpgrade := js.FuncOf(func(this js.Value, args []js.Value) any {
		db := req.Get("result")
		store := db.Call("createObjectStore", eventsStore, map[string]any{"keyPath": "id"})
		store.Call("createIndex", idxCreatedAt, "ca")
		store.Call("createIndex", idxKind, []any{"k", "ca"})
		store.Call("createIndex", idxAuthor, []any{"pk", "ca"})
		store.Call("createIndex", idxAuthorKind, []any{"pk", "k", "ca"})
		store.Call("createIndex", idxTag, "tg", map[string]any{"multiEntry": true})
		return nil
	})
	defer onUpgrade.Release()
	req.Set("onupgradeneeded", onUpgrade)
	db, err := await(req)
	req.Set("onupgradeneeded", js.Null())
	if err != nil {
		return err
	}
	b.db = db
	b.onVersionChange = js.FuncOf(func(js.Value, []js.Value) any {
		b.Close()
		ev := js.Global().Get("Event")
		if !ev.IsUndefined() && js.Global().Get("dispatchEvent").Type() == js.TypeFunction {
			js.Global().Call("dispatchEvent", ev.New(VersionChangeEvent))
		}
		return nil
	})
	db.Set("onversionchange", b.onVersionChange)
	return nil
}

func (b *IDBBackend) Close() {
	if !b.db.IsUndefined() && !b.db.IsNull() {
		b.db.Set("onversionchange", js.Null())
		b.db.Call("close")
	}
	b.db = js.Undefined()
}

// Serial satisfies Haven's DBBackend interface. Nothing in Haven reads it; it
// mirrors badger's 5-byte prefixed counter so callers see the same shape.
func (b *IDBBackend) Serial() []byte {
	next := b.serial.Add(1)
	return []byte{0, byte(next >> 24), byte(next >> 16), byte(next >> 8), byte(next)}
}

func (b *IDBBackend) tx(mode string) (js.Value, js.Value, error) {
	tx, err := jsCall(b.db, "transaction", eventsStore, mode)
	if err != nil {
		return js.Value{}, js.Value{}, err
	}
	return tx, tx.Call("objectStore", eventsStore), nil
}

func (b *IDBBackend) SaveEvent(ctx context.Context, evt *nostr.Event) error {
	if err := checkBounds(evt); err != nil {
		return err
	}
	tx, store, err := b.tx("readwrite")
	if err != nil {
		return err
	}
	if _, err := jsCall(store, "add", record(evt)); err != nil {
		tx.Call("abort")
		return err
	}
	if err := awaitTx(tx); err != nil {
		if isConstraintError(err) {
			return eventstore.ErrDupEvent
		}
		return err
	}
	return nil
}

func (b *IDBBackend) DeleteEvent(ctx context.Context, evt *nostr.Event) error {
	tx, store, err := b.tx("readwrite")
	if err != nil {
		return err
	}
	if _, err := jsCall(store, "delete", evt.ID); err != nil {
		tx.Call("abort")
		return err
	}
	return awaitTx(tx)
}

// ReplaceEvent mirrors eventstore/badger: inside one transaction, find what the
// event replaces, delete every older version and store it, unless a newer one
// is already there.
func (b *IDBBackend) ReplaceEvent(ctx context.Context, evt *nostr.Event) error {
	if err := checkBounds(evt); err != nil {
		return err
	}
	tx, store, err := b.tx("readwrite")
	if err != nil {
		return err
	}
	filter := nostr.Filter{Limit: 1, Kinds: []int{evt.Kind}, Authors: []string{evt.PubKey}}
	if nostr.IsAddressableKind(evt.Kind) {
		filter.Tags = nostr.TagMap{"d": []string{evt.Tags.GetD()}}
	}
	previous, err := b.query(store, filter, 10)
	if err != nil {
		tx.Call("abort")
		return fmt.Errorf("failed to query past events with %s: %w", filter, err)
	}
	shouldStore := true
	for _, prev := range previous {
		if isOlder(prev, evt) {
			if _, err := jsCall(store, "delete", prev.ID); err != nil {
				tx.Call("abort")
				return err
			}
		} else {
			shouldStore = false
		}
	}
	if shouldStore {
		if _, err := jsCall(store, "put", record(evt)); err != nil {
			tx.Call("abort")
			return err
		}
	}
	return awaitTx(tx)
}

func (b *IDBBackend) QueryEvents(ctx context.Context, filter nostr.Filter) (chan *nostr.Event, error) {
	ch := make(chan *nostr.Event)
	if filter.Search != "" {
		close(ch)
		return ch, nil
	}

	// Same limit rules as eventstore/badger query.go.
	maxLimit := b.MaxLimit
	var limit int
	if eventstore.IsNegentropySession(ctx) {
		maxLimit = b.MaxLimitNegentropy
		limit = maxLimit
	} else {
		limit = maxLimit / 4
	}
	if filter.Limit > 0 && filter.Limit <= maxLimit {
		limit = filter.Limit
	}
	if tlimit := nostr.GetTheoreticalLimit(filter); tlimit == 0 {
		close(ch)
		return ch, nil
	} else if tlimit > 0 {
		limit = tlimit
	}

	tx, store, err := b.tx("readonly")
	if err != nil {
		return nil, err
	}
	results, err := b.query(store, filter, limit)
	_ = tx // readonly: commits on its own once no request is pending
	if err != nil {
		return nil, err
	}

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

// CountEvents counts every match, with no limit, like eventstore/badger.
func (b *IDBBackend) CountEvents(ctx context.Context, filter nostr.Filter) (int64, error) {
	if filter.Search != "" {
		return 0, nil
	}
	if tlimit := nostr.GetTheoreticalLimit(filter); tlimit == 0 {
		return 0, nil
	}
	_, store, err := b.tx("readonly")
	if err != nil {
		return 0, err
	}
	results, err := b.query(store, filter, math.MaxInt32)
	return int64(len(results)), err
}

func checkBounds(evt *nostr.Event) error {
	if evt.CreatedAt > math.MaxUint32 || evt.Kind > math.MaxUint16 {
		return fmt.Errorf("event with values out of expected boundaries")
	}
	return nil
}

func isOlder(previous, next *nostr.Event) bool {
	return previous.CreatedAt < next.CreatedAt ||
		(previous.CreatedAt == next.CreatedAt && previous.ID > next.ID)
}

func isConstraintError(err error) bool {
	var de *DOMError
	return errors.As(err, &de) && de.Name == "ConstraintError"
}

// record is the stored shape of an event: raw JSON plus index fields.
func record(evt *nostr.Event) map[string]any {
	j, _ := evt.MarshalJSON()
	ca := int64(evt.CreatedAt)

	seen := make(map[[2]string]struct{}, len(evt.Tags))
	tg := make([]any, 0, len(evt.Tags))
	for _, tag := range evt.Tags {
		if len(tag) < 2 {
			continue
		}
		key := [2]string{tag[0], tag[1]}
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		tg = append(tg, []any{tag[0], tag[1], ca})
	}

	return map[string]any{
		"id": evt.ID,
		"j":  string(j),
		"ca": ca,
		"k":  evt.Kind,
		"pk": evt.PubKey,
		"tg": tg,
	}
}
