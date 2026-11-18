package main

import (
	"fmt"
	"os"
	"syscall"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// TestStoredCopyCPU measures the process CPU the read loop spends on a relay
// re-sending notes after a relaunch, with and without the stored-copy skip.
// Opt-in: NV_STORED_SIG_CPU=1 go test -tags libsecp256k1 -run TestStoredCopyCPU -v
func TestStoredCopyCPU(t *testing.T) {
	if testing.Short() || os.Getenv("NV_STORED_SIG_CPU") == "" {
		t.Skip("set NV_STORED_SIG_CPU=1")
	}
	const n = 2000
	feed, _ := storedSigStores(t)
	// The other searched stores hold data too, so a miss pays every lookup.
	for _, g := range []*DBBackend{&inboxDB, &outboxDB, &chatDB} {
		db := fallbackBackend(t.TempDir() + "/other")
		if err := db.Init(); err != nil {
			t.Fatal(err)
		}
		gdb := newGatedDB(db)
		t.Cleanup(gdb.Close)
		for i := 0; i < n; i++ {
			storeRaw(t, gdb, storedSigNote(t, nostr.GeneratePrivateKey(), fmt.Sprintf("other %d", i)))
		}
		*g = gdb
	}
	sk := nostr.GeneratePrivateKey()
	stored := make([]nostr.Event, n)
	fresh := make([]nostr.Event, n)
	for i := range stored {
		stored[i] = storedSigNote(t, sk, fmt.Sprintf("stored %d with a body about as long as a short note in a real feed", i))
		storeRaw(t, feed, stored[i])
		fresh[i] = storedSigNote(t, sk, fmt.Sprintf("fresh %d with a body about as long as a short note in a real feed", i))
	}
	storedIDsRead(t)
	cpu := func() time.Duration {
		var ru syscall.Rusage
		syscall.Getrusage(syscall.RUSAGE_SELF, &ru)
		return time.Duration(ru.Utime.Nano() + ru.Stime.Nano())
	}
	run := func(name string, evs []nostr.Event, skip bool) {
		if skip {
			nostr.SetStoredEventLookup(storedEventByID)
		} else {
			nostr.SetStoredEventLookup(nil)
		}
		var best time.Duration
		for round := 0; round < 7; round++ {
			nostr.ResetSigCache()
			c0 := cpu()
			if got := len(receivedEvents(t, evs)); got != n {
				t.Fatalf("%s: delivered %d of %d", name, got, n)
			}
			if d := cpu() - c0; round == 0 || d < best {
				best = d
			}
		}
		t.Logf("%-32s %6.0f ms CPU for %d notes (%.1f µs each, best of 7)", name, float64(best.Microseconds())/1000, n, float64(best.Microseconds())/n)
	}
	t.Cleanup(func() { nostr.SetStoredEventLookup(storedEventByID) })
	three := func(evs []nostr.Event) []nostr.Event {
		return append(append(append([]nostr.Event{}, evs...), evs...), evs...)
	}
	run3 := func(name string, evs []nostr.Event, skip bool) {
		if skip {
			nostr.SetStoredEventLookup(storedEventByID)
		} else {
			nostr.SetStoredEventLookup(nil)
		}
		var best time.Duration
		for round := 0; round < 7; round++ {
			nostr.ResetSigCache()
			c0 := cpu()
			if got := len(receivedEvents(t, three(evs))); got != 3*n {
				t.Fatalf("%s: delivered %d of %d", name, got, 3*n)
			}
			if d := cpu() - c0; round == 0 || d < best {
				best = d
			}
		}
		t.Logf("%-32s %6.0f ms CPU for %d notes x3 relays (%.1f µs per note)", name, float64(best.Microseconds())/1000, n, float64(best.Microseconds())/n)
	}
	if os.Getenv("NV_STORED_SIG_CPU") == "missonly" {
		for i := 0; i < 10; i++ {
			run("new notes: after", fresh, true)
		}
		return
	}
	for pass := 0; pass < 2; pass++ {
		run3("x3 re-sent, stored: before", stored, false)
		run3("x3 re-sent, stored: after", stored, true)
		run3("x3 new notes: after", fresh, true)
		run3("x3 new notes: before", fresh, false)
		run("re-sent, already stored: after", stored, true)
		run("re-sent, already stored: before", stored, false)
		run("new notes: before", fresh, false)
		run("new notes: after", fresh, true)
	}
}
