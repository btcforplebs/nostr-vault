package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/fasthttp/websocket"
	"github.com/nbd-wtf/go-nostr"
)

// The pool's read loop skips the signature check only for an exact copy of
// an event the local store holds (go-nostr sigcache.go storedCopy). These go
// through the real read loop: a fake upstream relay answers one REQ with
// crafted events, and the test sees which ones the subscription delivers.
// Run with and without -tags libsecp256k1.

// replayRelay answers every REQ with evs, then EOSE.
func replayRelay(t *testing.T, evs []nostr.Event) string {
	t.Helper()
	up := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := up.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer c.Close()
		for {
			_, msg, err := c.ReadMessage()
			if err != nil {
				return
			}
			var frame []json.RawMessage
			if json.Unmarshal(msg, &frame) != nil || len(frame) < 2 {
				continue
			}
			var typ, sub string
			json.Unmarshal(frame[0], &typ)
			json.Unmarshal(frame[1], &sub)
			if typ != "REQ" {
				continue
			}
			for _, ev := range evs {
				b, _ := json.Marshal(ev)
				c.WriteMessage(websocket.TextMessage, []byte(`["EVENT","`+sub+`",`+string(b)+`]`))
			}
			c.WriteMessage(websocket.TextMessage, []byte(`["EOSE","`+sub+`"]`))
		}
	}))
	t.Cleanup(srv.Close)
	return "ws" + strings.TrimPrefix(srv.URL, "http")
}

// received subscribes once and returns the contents the read loop let through.
func received(t *testing.T, evs []nostr.Event) map[string]bool {
	t.Helper()
	got := map[string]bool{}
	for _, ev := range receivedEvents(t, evs) {
		got[ev.Content] = true
	}
	return got
}

// receivedEvents subscribes once and returns what the read loop let through.
func receivedEvents(t *testing.T, evs []nostr.Event) []nostr.Event {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	r, err := nostr.RelayConnect(ctx, replayRelay(t, evs))
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	sub, err := r.Subscribe(ctx, nostr.Filters{{Kinds: []int{1, 24242}}})
	if err != nil {
		t.Fatal(err)
	}
	var got []nostr.Event
	for {
		select {
		case ev := <-sub.Events:
			got = append(got, *ev)
		case <-sub.EndOfStoredEvents:
			return got
		case <-ctx.Done():
			t.Fatal("no EOSE")
		}
	}
}

// storedSigStores points the searched stores at fresh, empty ones.
func storedSigStores(t *testing.T) (feed, blob DBBackend) {
	t.Helper()
	open := func(name string) DBBackend {
		db := fallbackBackend(t.TempDir() + "/" + name)
		if err := db.Init(); err != nil {
			t.Fatal(err)
		}
		g := newGatedDB(db) // as registerDB opens them
		t.Cleanup(g.Close)
		return g
	}
	prevFeed, prevIn, prevOut, prevChat, prevBlob := feedDB, inboxDB, outboxDB, chatDB, blossomDB
	t.Cleanup(func() { feedDB, inboxDB, outboxDB, chatDB, blossomDB = prevFeed, prevIn, prevOut, prevChat, prevBlob })
	feedDB, inboxDB, outboxDB, chatDB, blossomDB = open("feed"), nil, nil, nil, open("blossom")
	return feedDB, blossomDB
}

// storedIDsRead reads each searched store's id set, as the first lookup after
// a launch starts it, and waits until it is ready.
func storedIDsRead(t *testing.T) {
	t.Helper()
	for _, db := range []DBBackend{feedDB, inboxDB, outboxDB, chatDB} {
		g, ok := db.(*gatedDB)
		if !ok {
			continue
		}
		set := storedIDSetFor(g)
		for i := 0; set != nil && !set.ready.Load(); i++ {
			if i > 500 {
				t.Fatal("id set never became ready")
			}
			time.Sleep(10 * time.Millisecond)
		}
	}
}

func storedSigNote(t *testing.T, sk, content string) nostr.Event {
	t.Helper()
	ev := nostr.Event{Kind: 1, Content: content, CreatedAt: nostr.Now(), Tags: nostr.Tags{}}
	if err := ev.Sign(sk); err != nil {
		t.Fatal(err)
	}
	return ev
}

func storeRaw(t *testing.T, db DBBackend, ev nostr.Event) {
	t.Helper()
	if err := db.SaveEvent(context.Background(), &ev); err != nil {
		t.Fatal(err)
	}
}

func TestStoredCopySkipsTheCheck(t *testing.T) {
	feed, _ := storedSigStores(t)
	nostr.ResetSigCache()
	ev := storedSigNote(t, nostr.GeneratePrivateKey(), "already here")
	storeRaw(t, feed, ev)
	storedIDsRead(t)

	before := nostr.StoredCopyHits()
	if got := received(t, []nostr.Event{ev}); !got["already here"] {
		t.Fatal("the stored copy was not delivered")
	}
	if nostr.StoredCopyHits() != before+1 {
		t.Fatal("the stored copy was verified again")
	}
	if _, misses := nostr.SigCacheStats(); misses != 0 {
		t.Fatalf("CheckSignature ran %d times for a stored copy", misses)
	}
}

func TestStoredCopyNewEventsAreStillChecked(t *testing.T) {
	storedSigStores(t)
	nostr.ResetSigCache()
	good := storedSigNote(t, nostr.GeneratePrivateKey(), "new and valid")
	bad := storedSigNote(t, nostr.GeneratePrivateKey(), "new and forged")
	bad.Sig = sigCacheFlip(bad.Sig, 5)

	got := received(t, []nostr.Event{good, bad})
	if !got["new and valid"] || got["new and forged"] {
		t.Fatalf("got %v: want the valid new note only", got)
	}
	if _, misses := nostr.SigCacheStats(); misses != 2 {
		t.Fatalf("misses = %d, want both new notes verified", misses)
	}
}

// A copy of a known id with anything changed must still be verified, and
// refused when that fails.
func TestStoredCopyForgeryOnAKnownIDIsRefused(t *testing.T) {
	feed, _ := storedSigStores(t)
	sk := nostr.GeneratePrivateKey()
	ev := storedSigNote(t, sk, "original")
	other := storedSigNote(t, nostr.GeneratePrivateKey(), "someone else")
	storeRaw(t, feed, ev)
	storedIDsRead(t)

	cases := map[string]func(e *nostr.Event){
		"forged sig, same id":          func(e *nostr.Event) { e.Sig = sigCacheFlip(e.Sig, 10) },
		"sig from another event":       func(e *nostr.Event) { e.Sig = other.Sig },
		"content changed, same id+sig": func(e *nostr.Event) { e.Content = "forged" },
		"tags changed, same id+sig":    func(e *nostr.Event) { e.Tags = nostr.Tags{{"p", other.PubKey}} },
		"created_at changed":           func(e *nostr.Event) { e.CreatedAt++ },
		"pubkey swapped, same id+sig":  func(e *nostr.Event) { e.PubKey = other.PubKey },
		"uppercase sig, same bytes":    func(e *nostr.Event) { e.Sig = upperFirstLetter(e.Sig) },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			nostr.ResetSigCache()
			forged := ev
			mutate(&forged)
			before := nostr.StoredCopyHits()
			got := receivedEvents(t, []nostr.Event{forged})
			if nostr.StoredCopyHits() != before {
				t.Fatal("a changed copy was taken as the stored one")
			}
			// Hex is case-blind, so that one is a valid sig: verified, not skipped.
			if name != "uppercase sig, same bytes" && len(got) > 0 {
				t.Fatalf("a forged copy of a known id was delivered: %+v", got[0])
			}
		})
	}
}

// The read loop checks the signature over the content, not the claimed id,
// so the store can hold a real note under a doctored id. That copy must not
// vouch for a forged note whose content does hash to the doctored id.
func TestStoredCopyDoctoredIDDoesNotVouch(t *testing.T) {
	feed, _ := storedSigStores(t)
	nostr.ResetSigCache()
	victim := nostr.GeneratePrivateKey()
	real := storedSigNote(t, victim, "what the victim said")

	forged := real
	forged.Content = "what the victim never said"
	forged.ID = forged.GetID()

	planted := real
	planted.ID = forged.ID // real content and sig, doctored id
	if ok, _ := planted.CheckSignature(); !ok {
		t.Fatal("setup: the planted copy should pass a sig-only check, as the read loop's does")
	}
	storeRaw(t, feed, planted)
	storedIDsRead(t)

	before := nostr.StoredCopyHits()
	if got := received(t, []nostr.Event{forged}); got[forged.Content] {
		t.Fatal("a forged note was delivered on the strength of a doctored stored copy")
	}
	if nostr.StoredCopyHits() != before {
		t.Fatal("the doctored stored copy vouched for another content")
	}
}

// The blob index holds the relay's own unsigned records; it is never searched.
func TestStoredCopyBlobIndexDoesNotVouch(t *testing.T) {
	_, blob := storedSigStores(t)
	nostr.ResetSigCache()
	rec := storedSigNote(t, nostr.GeneratePrivateKey(), "blob record")
	rec.Kind = 24242
	rec.ID = rec.GetID()
	rec.Sig = strings.Repeat("0", 128) // unsigned, as the blob index keeps them
	storeRaw(t, blob, rec)
	storedIDsRead(t)

	if got := received(t, []nostr.Event{rec}); got["blob record"] {
		t.Fatal("an unsigned record was delivered because the blob index holds it")
	}
}

// With no lookup installed nothing is skipped.
func TestStoredCopyOffWithoutLookup(t *testing.T) {
	feed, _ := storedSigStores(t)
	nostr.SetStoredEventLookup(nil)
	t.Cleanup(func() { nostr.SetStoredEventLookup(storedEventByID) })
	nostr.ResetSigCache()
	ev := storedSigNote(t, nostr.GeneratePrivateKey(), "stored")
	storeRaw(t, feed, ev)
	storedIDsRead(t)
	before := nostr.StoredCopyHits()
	if got := received(t, []nostr.Event{ev}); !got["stored"] || nostr.StoredCopyHits() != before {
		t.Fatalf("got %v, hits moved: want a normal verify", got)
	}
}

// upperFirstLetter upper-cases the first a-f in a hex string: the same bytes
// in a different string.
func upperFirstLetter(h string) string {
	i := strings.IndexAny(h, "abcdef")
	if i < 0 {
		panic("hex with no letter")
	}
	return h[:i] + strings.ToUpper(h[i:i+1]) + h[i+1:]
}

// The id set is read once per store; a note stored later is missing from it
// and so is verified as before, never refused.
func TestStoredCopyNoteStoredAfterTheSetIsVerified(t *testing.T) {
	feed, _ := storedSigStores(t)
	storedIDsRead(t)
	nostr.ResetSigCache()
	ev := storedSigNote(t, nostr.GeneratePrivateKey(), "stored later")
	storeRaw(t, feed, ev)
	before := nostr.StoredCopyHits()
	if got := received(t, []nostr.Event{ev}); !got["stored later"] {
		t.Fatal("a note stored after the set was read was not delivered")
	}
	if nostr.StoredCopyHits() != before {
		t.Fatal("skipped on a set that cannot hold it")
	}
	if _, misses := nostr.SigCacheStats(); misses != 1 {
		t.Fatalf("misses = %d, want it verified once", misses)
	}
}

// Before a store's set is ready nothing is skipped.
func TestStoredCopyVerifiesUntilTheSetIsRead(t *testing.T) {
	feed, _ := storedSigStores(t)
	ev := storedSigNote(t, nostr.GeneratePrivateKey(), "early")
	storeRaw(t, feed, ev)
	if feed.(*gatedDB).mayHoldID(ev.ID) {
		// The set may already be ready on a fast machine; then it must hold it.
		return
	}
	set := storedIDSetFor(feed.(*gatedDB))
	if set != nil && set.ready.Load() {
		t.Fatal("a ready set does not hold a stored id")
	}
}

// The set holds what the store held when it was read, and nothing else.
func TestStoredIDSetMatchesTheStore(t *testing.T) {
	feed, _ := storedSigStores(t)
	var in []nostr.Event
	for i := 0; i < 50; i++ {
		ev := storedSigNote(t, nostr.GeneratePrivateKey(), "n")
		storeRaw(t, feed, ev)
		in = append(in, ev)
	}
	storedIDsRead(t)
	g := feed.(*gatedDB)
	for _, ev := range in {
		if !g.mayHoldID(ev.ID) {
			t.Fatalf("set misses stored id %s", ev.ID)
		}
	}
	for i := 0; i < 50; i++ {
		if g.mayHoldID(storedSigNote(t, nostr.GeneratePrivateKey(), "x").ID) {
			t.Fatal("set holds an id never stored")
		}
	}
}
