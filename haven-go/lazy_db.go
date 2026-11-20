package main

import (
	"context"
	"fmt"
	"log/slog"
	"sync"
	"sync/atomic"

	"github.com/nbd-wtf/go-nostr"
)

// lazyDB opens its store on the first call instead of at startup. Each open
// Badger store keeps a 16 MiB memtable arena (8 on phones) and two
// compactors for as long as it is open, and several stores are touched
// rarely or never in a session (lazyDBNames), so they open when used.
//
// It sits inside the gate (registerDB), so a relay stop waits for or
// refuses its calls exactly as for an eager store; Close closes the store
// only if it was ever opened, and a closed lazyDB never opens again.
type lazyDB struct {
	name string
	open func() (DBBackend, error)

	cur    atomic.Pointer[DBBackend]
	mu     sync.Mutex // serialises open and close
	closed bool
}

func newLazyDB(name string, open func() (DBBackend, error)) *lazyDB {
	return &lazyDB{name: name, open: open}
}

// opened is the store if it is open, else nil. It never opens it.
func (l *lazyDB) opened() DBBackend {
	if p := l.cur.Load(); p != nil {
		return *p
	}
	return nil
}

// get returns the store, opening it on first use. A failed open is
// returned to the caller and tried again on the next call.
func (l *lazyDB) get() (DBBackend, error) {
	if db := l.opened(); db != nil {
		return db, nil
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if db := l.opened(); db != nil {
		return db, nil
	}
	if l.closed {
		return nil, errDBClosing
	}
	db, err := l.open()
	if err != nil {
		slog.Warn("database failed to open on first use", "name", l.name, "err", err)
		return nil, fmt.Errorf("%sDB open failed: %w", l.name, err)
	}
	l.cur.Store(&db)
	startupMark("store " + l.name + " open (first use)")
	return db, nil
}

func (l *lazyDB) Init() error { return nil } // opens on first use

func (l *lazyDB) Close() {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.closed = true
	if db := l.opened(); db != nil {
		db.Close()
	}
}

func (l *lazyDB) Serial() []byte {
	db, err := l.get()
	if err != nil {
		return nil
	}
	return db.Serial()
}

func (l *lazyDB) CountEvents(ctx context.Context, f nostr.Filter) (int64, error) {
	db, err := l.get()
	if err != nil {
		return 0, err
	}
	return db.CountEvents(ctx, f)
}

func (l *lazyDB) DeleteEvent(ctx context.Context, evt *nostr.Event) error {
	db, err := l.get()
	if err != nil {
		return err
	}
	return db.DeleteEvent(ctx, evt)
}

func (l *lazyDB) QueryEvents(ctx context.Context, f nostr.Filter) (chan *nostr.Event, error) {
	db, err := l.get()
	if err != nil {
		return nil, err
	}
	return db.QueryEvents(ctx, f)
}

func (l *lazyDB) SaveEvent(ctx context.Context, evt *nostr.Event) error {
	db, err := l.get()
	if err != nil {
		return err
	}
	return db.SaveEvent(ctx, evt)
}

func (l *lazyDB) ReplaceEvent(ctx context.Context, evt *nostr.Event) error {
	db, err := l.get()
	if err != nil {
		return err
	}
	return db.ReplaceEvent(ctx, evt)
}

// Compact compacts the store if it is open; a store never opened has
// nothing to give back.
func (l *lazyDB) Compact(hold func(step func() error) error) error {
	c, ok := l.opened().(compactor)
	if !ok {
		return nil
	}
	return c.Compact(hold)
}

// openDB opens one named store. A panic inside the open comes back as an
// error rather than ending the app.
func openDB(name string) (db DBBackend, err error) {
	defer func() {
		if r := recover(); r != nil {
			db, err = nil, fmt.Errorf("panic while opening: %v", r)
		}
	}()
	slog.Info(fmt.Sprintf("Initializing %s database", name))
	inner := newDBBackend("db/" + name)
	if err := inner.Init(); err != nil {
		return nil, err
	}
	return inner, nil
}

// registerLazyDBs registers the lazyDBNames among names as lazy stores and
// returns the rest, to open now. Caller holds dbMu.
func registerLazyDBs(names []string) []string {
	var now []string
	for _, name := range names {
		if containsAll(lazyDBNames, []string{name}) {
			registerDB(name, newLazyDB(name, func() (DBBackend, error) { return openDB(name) }))
			continue
		}
		now = append(now, name)
	}
	return now
}
