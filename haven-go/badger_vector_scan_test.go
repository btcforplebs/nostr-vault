//go:build !wasm

package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"runtime"
	"runtime/debug"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/fiatjaf/eventstore"
	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/internal/negsync"
)

const vectorTestEvents = 100_000

// fillVectorStore writes n kind-1 notes by one author, ~1 KB of content and a
// few tags each (a feed or inbox shape), three to a second.
func fillVectorStore(t *testing.T, n int) (*badgerStore, string) {
	t.Helper()
	s := newBadgerStoreFor(t.TempDir(), "darwin")
	if err := s.Init(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	author := strings.Repeat("ab", 32)
	body := strings.Repeat("vault note body ", 64) // 1 KiB
	ctx := context.Background()
	for i := 0; i < n; i++ {
		sum := sha256.Sum256([]byte{byte(i), byte(i >> 8), byte(i >> 16), byte(i >> 24)})
		id := hex.EncodeToString(sum[:])
		ev := &nostr.Event{
			ID:        id,
			PubKey:    author,
			CreatedAt: nostr.Timestamp(1_700_000_000 - i/3),
			Kind:      1,
			Content:   body,
			Tags:      nostr.Tags{{"p", id}, {"e", id}, {"t", "vault"}, {"client", "nostr-vault"}},
			Sig:       strings.Repeat("cd", 64),
		}
		if err := s.BadgerBackend.SaveEvent(ctx, ev); err != nil {
			t.Fatal(err)
		}
	}
	return s, author
}

// heapPeak runs fn while sampling the live heap, with the GC kept eager so
// garbage doesn't pass for live data. It returns the peak and what is still
// held after fn (kept alive through keep) over the starting heap.
func heapPeak(fn func() any) (peak, held uint64) {
	defer debug.SetGCPercent(debug.SetGCPercent(5))
	runtime.GC()
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	base := m.HeapAlloc
	var top atomic.Uint64
	stop := make(chan struct{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		var s runtime.MemStats
		for {
			runtime.ReadMemStats(&s)
			if s.HeapAlloc > base && s.HeapAlloc-base > top.Load() {
				top.Store(s.HeapAlloc - base)
			}
			select {
			case <-stop:
				return
			case <-time.After(2 * time.Millisecond):
			}
		}
	}()
	keep := fn()
	close(stop)
	<-done
	runtime.GC()
	runtime.ReadMemStats(&m)
	if m.HeapAlloc > base {
		held = m.HeapAlloc - base
	}
	runtime.KeepAlive(keep)
	return top.Load(), held
}

// A vector build over 100k stored notes used to decode all of them, whole,
// into one slice (Badger collects a query's result before sending it): about
// 150 MB live for a list of ids. It must now hold one page and the stubs.
func TestVectorBuildDoesNotHoldWholeEvents(t *testing.T) {
	if testing.Short() {
		t.Skip("writes 100k events")
	}
	s, author := fillVectorStore(t, vectorTestEvents)
	store := &feedNegStore{feed: eventstore.RelayWrapper{Store: s}}
	f := nostr.Filter{Authors: []string{author}, Kinds: []int{1}}

	var got []*nostr.Event
	peakQ, heldQ := heapPeak(func() any {
		var err error
		got, err = store.QuerySync(negsync.ForVector(context.Background()), f)
		if err != nil {
			t.Fatal(err)
		}
		return got
	})
	if len(got) != vectorTestEvents {
		t.Fatalf("vector query returned %d events, want %d", len(got), vectorTestEvents)
	}
	if got[0].Content != "" || got[0].Tags != nil || got[0].Sig != "" {
		t.Error("vector query returned whole events, not id+created_at stubs")
	}
	got = nil

	var lv *negsync.LocalVector
	peakB, heldB := heapPeak(func() any {
		var err error
		lv, err = negsync.BuildVector(context.Background(), store, f)
		if err != nil {
			t.Fatal(err)
		}
		return lv
	})
	t.Logf("vector query over %d events: peak %d MB, result held %d MB", vectorTestEvents, peakQ>>20, heldQ>>20)
	t.Logf("BuildVector over %d events: peak %d MB, vector held %d MB", vectorTestEvents, peakB>>20, heldB>>20)

	// Whole events here are ~1.5 KB each, ~150 MB for 100k; stubs are ~0.2 KB.
	const ceiling = 64 << 20
	if heldQ > ceiling {
		t.Errorf("vector query result holds %d MB for %d events; whole events are back", heldQ>>20, vectorTestEvents)
	}
	if peakB > ceiling {
		t.Errorf("BuildVector peaked at %d MB live for %d events, over %d MB", peakB>>20, vectorTestEvents, ceiling>>20)
	}
}

// The stub scan finds exactly the events the whole-event query does.
func TestVectorScanMatchesWholeQuery(t *testing.T) {
	s, author := fillVectorStore(t, 25_000)
	old := vectorScanPage
	vectorScanPage = 1_000 // many pages, many split seconds
	defer func() { vectorScanPage = old }()

	for _, f := range []nostr.Filter{
		{Authors: []string{author}, Kinds: []int{1}},
		{Kinds: []int{1}, Since: ptrTs(1_700_000_000 - 4_000)},
		{Authors: []string{author}, Until: ptrTs(1_700_000_000 - 1_234), Limit: 5_000},
	} {
		ctx := eventstore.SetNegentropy(context.Background())
		whole, err := eventstore.RelayWrapper{Store: s}.QuerySync(ctx, f)
		if err != nil {
			t.Fatal(err)
		}
		stubs, err := eventstore.RelayWrapper{Store: s}.QuerySync(negsync.ForVector(ctx), f)
		if err != nil {
			t.Fatal(err)
		}
		want := map[string]nostr.Timestamp{}
		for _, ev := range whole {
			want[ev.ID] = ev.CreatedAt
		}
		if len(stubs) != len(want) {
			t.Fatalf("%v: stub scan found %d, whole query %d", f, len(stubs), len(want))
		}
		for _, ev := range stubs {
			if ts, ok := want[ev.ID]; !ok || ts != ev.CreatedAt {
				t.Fatalf("%v: stub %s@%d not in the whole query", f, ev.ID, ev.CreatedAt)
			}
			delete(want, ev.ID) // a repeat would now miss
		}
	}
}

func ptrTs(ts nostr.Timestamp) *nostr.Timestamp { return &ts }

// Two vector scans on the store never run together: the second sends
// nothing until the first is drained.
func TestVectorScansTakeTurns(t *testing.T) {
	s, author := fillVectorStore(t, 2_000)
	f := nostr.Filter{Authors: []string{author}}
	ctx := negsync.ForVector(context.Background())

	first, err := s.QueryEvents(ctx, f)
	if err != nil {
		t.Fatal(err)
	}
	<-first // the first scan holds the gate and is mid-send
	second, err := s.QueryEvents(ctx, f)
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-second:
		t.Fatal("second scan ran while the first held the gate")
	case <-time.After(200 * time.Millisecond):
	}
	n := 1
	for range first {
		n++
	}
	select {
	case <-second:
	case <-time.After(5 * time.Second):
		t.Fatal("second scan never started after the first finished")
	}
	for range second {
	}
	if n != 2_000 {
		t.Fatalf("first scan sent %d, want 2000", n)
	}
}

// Ordinary queries (a REQ, an export) still get whole events.
func TestUnmarkedQueriesStayWhole(t *testing.T) {
	s, author := fillVectorStore(t, 10)
	ctx := eventstore.SetNegentropy(context.Background())
	evs, err := eventstore.RelayWrapper{Store: s}.QuerySync(ctx, nostr.Filter{Authors: []string{author}})
	if err != nil || len(evs) != 10 || evs[0].Content == "" || evs[0].Sig == "" {
		t.Fatalf("unmarked query: %d events, err %v", len(evs), err)
	}
}
