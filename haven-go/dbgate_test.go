package main

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// fakeStore streams n events from QueryEvents, one at a time, and records
// whether it was closed while a query was still sending.
type fakeStore struct {
	DBBackend
	n             int
	inQuery       atomic.Int32
	closed        chan struct{}
	closedMidSend bool
}

func newFakeStore(n int) *fakeStore {
	return &fakeStore{n: n, closed: make(chan struct{})}
}

func (f *fakeStore) QueryEvents(ctx context.Context, _ nostr.Filter) (chan *nostr.Event, error) {
	ch := make(chan *nostr.Event)
	f.inQuery.Add(1) // like eventstore's open read transaction
	go func() {
		defer close(ch)
		defer f.inQuery.Add(-1)
		for i := 0; i < f.n; i++ {
			ch <- &nostr.Event{} // like eventstore: no ctx check while sending
		}
	}()
	return ch, nil
}

func (f *fakeStore) SaveEvent(context.Context, *nostr.Event) error { return nil }
func (f *fakeStore) Close() {
	f.closedMidSend = f.inQuery.Load() > 0
	close(f.closed)
}

// A query whose reader walks away (ctx cancelled) must still let the store
// finish, and the store must not close until it has.
func TestGatedDBCloseWaitsForAbandonedQuery(t *testing.T) {
	store := newFakeStore(100)
	g := newGatedDB(store)
	ctx, cancel := context.WithCancel(context.Background())
	ch, err := g.QueryEvents(ctx, nostr.Filter{})
	if err != nil {
		t.Fatal(err)
	}
	<-ch // reader takes one event, then leaves
	cancel()

	g.Close()
	if store.closedMidSend {
		t.Fatal("store closed while its query was still sending")
	}
	select {
	case <-store.closed:
	default:
		t.Fatal("Close returned before the store closed")
	}
}

// After close begins, new calls are refused, and a query still being read
// keeps the store open until it is drained.
func TestGatedDBRefusesAfterCloseAndDefersToLastReader(t *testing.T) {
	store := newFakeStore(3)
	g := newGatedDB(store)
	ch, err := g.QueryEvents(context.Background(), nostr.Filter{})
	if err != nil {
		t.Fatal(err)
	}

	allClosed, inTime := closeGatedDBs([]*gatedDB{g}, 50*time.Millisecond)
	if inTime {
		t.Fatal("store closed while a reader still held it")
	}
	if err := g.SaveEvent(context.Background(), &nostr.Event{}); err != errDBClosing {
		t.Fatalf("SaveEvent after close = %v, want errDBClosing", err)
	}
	if _, err := g.QueryEvents(context.Background(), nostr.Filter{}); err != errDBClosing {
		t.Fatalf("QueryEvents after close = %v, want errDBClosing", err)
	}

	for range ch {
	}
	select {
	case <-allClosed:
	case <-time.After(2 * time.Second):
		t.Fatal("store did not close after its last reader finished")
	}
	if store.closedMidSend {
		t.Fatal("store closed while its query was still sending")
	}
}
