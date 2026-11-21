//go:build !wasm

package main

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// The lazy stores are registered at start but their directories appear only
// when something first reads or writes them; the rest open with the relay.
func TestLazyStoresOpenOnFirstUse(t *testing.T) {
	t.Chdir(t.TempDir())
	names := []string{"private", "chat", "outbox", "inbox", "blossom", "feed", "lists", "listsimport", "files"}
	if err := GranularInitDBs(names); err != nil {
		t.Fatal(err)
	}
	defer CloseDBs()
	for _, name := range names {
		_, err := os.Stat("db/" + name)
		lazy := containsAll([]string{"private", "listsimport", "files"}, []string{name})
		if lazy && err == nil {
			t.Fatalf("%s opened at start", name)
		}
		if !lazy && err != nil {
			t.Fatalf("%s not opened at start: %v", name, err)
		}
	}
	ctx := context.Background()
	evt := &nostr.Event{Kind: 1, CreatedAt: nostr.Now(), Content: "x"}
	evt.Sign(nostr.GeneratePrivateKey())
	if err := privateDB.SaveEvent(ctx, evt); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat("db/private"); err != nil {
		t.Fatalf("private not opened by its first write: %v", err)
	}
	n, err := privateDB.CountEvents(ctx, nostr.Filter{IDs: []string{evt.ID}})
	if err != nil || n != 1 {
		t.Fatalf("count after write = %d, %v", n, err)
	}
	if _, err := os.Stat("db/files"); err == nil {
		t.Fatal("files opened by a write to private")
	}
}

type countingOpen struct{ opens, closes int }

func (c *countingOpen) open() (DBBackend, error) {
	c.opens++
	return &closeCounter{c: c}, nil
}

// closeCounter is an empty store that counts its closes.
type closeCounter struct{ c *countingOpen }

func (s *closeCounter) Init() error                                              { return nil }
func (s *closeCounter) Close()                                                   { s.c.closes++ }
func (s *closeCounter) Serial() []byte                                           { return nil }
func (s *closeCounter) CountEvents(context.Context, nostr.Filter) (int64, error) { return 0, nil }
func (s *closeCounter) DeleteEvent(context.Context, *nostr.Event) error          { return nil }
func (s *closeCounter) SaveEvent(context.Context, *nostr.Event) error            { return nil }
func (s *closeCounter) ReplaceEvent(context.Context, *nostr.Event) error         { return nil }
func (s *closeCounter) QueryEvents(context.Context, nostr.Filter) (chan *nostr.Event, error) {
	ch := make(chan *nostr.Event)
	close(ch)
	return ch, nil
}

// A store never used is never opened, not even to close it, and a closed
// lazy store refuses calls instead of opening again.
func TestLazyDBCloseNeverOpens(t *testing.T) {
	c := &countingOpen{}
	l := newLazyDB("t", c.open)
	l.Close()
	if c.opens != 0 {
		t.Fatalf("close opened the store %d times", c.opens)
	}
	if _, err := l.QueryEvents(context.Background(), nostr.Filter{}); err != errDBClosing {
		t.Fatalf("query after close: %v, want errDBClosing", err)
	}
	if c.opens != 0 {
		t.Fatal("a closed lazy store opened")
	}
}

// Many first calls at once open the store once, and close closes it once.
func TestLazyDBOpensOnce(t *testing.T) {
	c := &countingOpen{}
	l := newLazyDB("t", c.open)
	done := make(chan struct{})
	for range 16 {
		go func() {
			l.CountEvents(context.Background(), nostr.Filter{})
			done <- struct{}{}
		}()
	}
	for range 16 {
		<-done
	}
	l.Close()
	if c.opens != 1 || c.closes != 1 {
		t.Fatalf("opens=%d closes=%d, want 1 and 1", c.opens, c.closes)
	}
}

// A failed open is answered from memory for lazyOpenRetry, then tried again.
func TestLazyDBFailedOpenWaitsBeforeRetry(t *testing.T) {
	opens := 0
	fail := true
	l := newLazyDB("t", func() (DBBackend, error) {
		opens++
		if fail {
			return nil, errors.New("broken")
		}
		return &closeCounter{c: &countingOpen{}}, nil
	})
	for range 10 {
		if _, err := l.CountEvents(context.Background(), nostr.Filter{}); err == nil {
			t.Fatal("open failure not returned")
		}
	}
	if opens != 1 {
		t.Fatalf("a failed open was tried %d times inside the retry window", opens)
	}
	fail = false
	l.failedAt = time.Now().Add(-lazyOpenRetry)
	if _, err := l.CountEvents(context.Background(), nostr.Filter{}); err != nil || opens != 2 {
		t.Fatalf("after the window: err=%v opens=%d", err, opens)
	}
}

// Close drops the open store, so nothing reaches it through the lock-free path.
func TestLazyDBCloseDropsTheStore(t *testing.T) {
	l := newLazyDB("t", (&countingOpen{}).open)
	l.CountEvents(context.Background(), nostr.Filter{})
	if l.opened() == nil {
		t.Fatal("not open after a call")
	}
	l.Close()
	if l.opened() != nil {
		t.Fatal("closed store still handed out")
	}
	if s := l.Serial(); s != nil {
		t.Fatalf("Serial after close = %v", s)
	}
}
