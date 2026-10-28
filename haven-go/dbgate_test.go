package main

import (
	"context"
	"io"
	"strconv"
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

// After close begins, new calls are refused, and a query still open is cut
// short: its channel ends, the store finishes its own send, then closes.
// Every CloseDBs caller is end of life (relay stop, or a deferred close
// after a backup/import), so nobody needs the rest of those results.
func TestGatedDBRefusesAfterCloseAndCutsOpenQuery(t *testing.T) {
	store := newFakeStore(100)
	g := newGatedDB(store)
	ch, err := g.QueryEvents(context.Background(), nostr.Filter{})
	if err != nil {
		t.Fatal(err)
	}
	<-ch // reader is mid-query

	allClosed, inTime := closeGatedDBs([]*gatedDB{g}, 2*time.Second)
	if !inTime {
		t.Fatal("store not closed in time: open query still holds the gate")
	}
	if err := g.SaveEvent(context.Background(), &nostr.Event{}); err != errDBClosing {
		t.Fatalf("SaveEvent after close = %v, want errDBClosing", err)
	}
	if _, err := g.QueryEvents(context.Background(), nostr.Filter{}); err != errDBClosing {
		t.Fatalf("QueryEvents after close = %v, want errDBClosing", err)
	}
	n := 0
	for range ch {
		n++
	}
	if n > 1 {
		t.Fatalf("reader got %d more events after close, want at most 1", n)
	}
	<-allClosed
	if store.closedMidSend {
		t.Fatal("store closed while its query was still sending")
	}
}

// A reader that stops reading without ever cancelling ctx (exportDB after a
// write error, with context.Background) must not keep the store open past
// close.
func TestGatedDBCloseStopsUncancelledAbandonedQuery(t *testing.T) {
	store := newFakeStore(100)
	g := newGatedDB(store)
	ch, err := g.QueryEvents(context.Background(), nostr.Filter{})
	if err != nil {
		t.Fatal(err)
	}
	<-ch // reader takes one event, then walks away; ctx is never cancelled

	if _, inTime := closeGatedDBs([]*gatedDB{g}, 2*time.Second); !inTime {
		t.Fatal("store not closed in time: abandoned query still holds the gate")
	}
	if store.closedMidSend {
		t.Fatal("store closed while its query was still sending")
	}
}

// A backup whose query close cut short must fail, not save a partial file.
func TestExportDBFailsWhenCloseCutsQuery(t *testing.T) {
	store := &cutStore{}
	g := newGatedDB(store)
	store.g = g
	if err := exportDB(context.Background(), g, io.Discard); err != errDBClosing {
		t.Fatalf("exportDB = %v, want errDBClosing", err)
	}
}

// cutStore returns one page of events, then has its relay cycle begin
// closing during the second query, which close cuts off before any event.
type cutStore struct {
	DBBackend
	g     *gatedDB
	calls int
}

func (s *cutStore) QueryEvents(context.Context, nostr.Filter) (chan *nostr.Event, error) {
	s.calls++
	ch := make(chan *nostr.Event, 3)
	if s.calls == 1 {
		for i := 3; i > 0; i-- {
			ch <- &nostr.Event{ID: strconv.Itoa(i), CreatedAt: nostr.Timestamp(i * 10)}
		}
	} else {
		go s.g.beginClose() // the gate is held by this query, so it only marks closing
		for !s.g.isClosing() {
			time.Sleep(time.Millisecond)
		}
	}
	close(ch)
	return ch, nil
}

func (s *cutStore) Close() {}
