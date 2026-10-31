package main

import (
	"context"
	"fmt"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/fiatjaf/eventstore"
	"github.com/fiatjaf/khatru"
	"github.com/nbd-wtf/go-nostr"
)

// Tron audit 633d5552, Logen's rule: the vault never sends an older copy of a
// user's list over a newer one, and does not send one when no relay answered
// the check.

// listRelay is a khatru relay with a real store that records every event
// published to it.
type listRelay struct {
	url  string
	mu   sync.Mutex
	got  []string
	repl eventstore.RelayWrapper
}

func (r *listRelay) received(id string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, g := range r.got {
		if g == id {
			return true
		}
	}
	return false
}

func newListRelay(t *testing.T, holds ...*nostr.Event) *listRelay {
	t.Helper()
	skipWithoutFS(t)
	store := newTestStore(t)
	for _, ev := range holds {
		if err := store.Publish(context.Background(), *ev); err != nil {
			t.Fatal(err)
		}
	}
	lr := &listRelay{repl: store}
	r := khatru.NewRelay()
	note := func(_ context.Context, ev *nostr.Event) error {
		lr.mu.Lock()
		lr.got = append(lr.got, ev.ID)
		lr.mu.Unlock()
		return nil
	}
	r.StoreEvent = append(r.StoreEvent, note, store.Store.SaveEvent)
	r.ReplaceEvent = append(r.ReplaceEvent, note, store.Store.ReplaceEvent)
	r.QueryEvents = append(r.QueryEvents, store.Store.QueryEvents)
	srv := httptest.NewServer(r)
	t.Cleanup(srv.Close)
	lr.url = "ws" + strings.TrimPrefix(srv.URL, "http")
	return lr
}

func signedList(t *testing.T, sk string, kind int, at time.Time, tags nostr.Tags) *nostr.Event {
	t.Helper()
	ev := &nostr.Event{Kind: kind, CreatedAt: nostr.Timestamp(at.Unix()), Tags: tags}
	if err := ev.Sign(sk); err != nil {
		t.Fatal(err)
	}
	return ev
}

func relayTags(urls ...string) nostr.Tags {
	var tags nostr.Tags
	for _, u := range urls {
		tags = append(tags, nostr.Tag{"r", u})
	}
	return tags
}

func queuedNow(ev *nostr.Event) pendingBlast {
	return pendingBlast{Event: *ev, QueuedAt: time.Now().Unix()}
}

// A relay list queued while offline must not go out once a newer copy was
// published elsewhere: the retry drops it and the relay never sees it.
func TestQueuedListDroppedWhenRelayHoldsNewer(t *testing.T) {
	sk := nostr.GeneratePrivateKey()
	now := time.Now()
	newer := signedList(t, sk, 10002, now.Add(-time.Minute), relayTags("wss://new.example"))
	relay := newListRelay(t, newer)
	ctx, _ := blastTestSetup(t, relay.url)
	pk, _ := nostr.GetPublicKey(sk)
	config.WhitelistedPubKeys = map[string]struct{}{pk: {}}

	older := signedList(t, sk, 10002, now.Add(-time.Hour), relayTags("wss://old.example"))
	q := openBlastQueue(blastPendingFile)
	q.items = []pendingBlast{queuedNow(older)}
	retryPendingOnce(ctx, q)

	if relay.received(older.ID) {
		t.Fatal("the older relay list was sent over the newer one")
	}
	if s := q.snapshot(); len(s) != 0 {
		t.Fatalf("older list still queued: %+v", s)
	}
}

// The vault itself holds a newer copy (an edit made since): drop ours.
func TestQueuedListDroppedWhenVaultHoldsNewer(t *testing.T) {
	sk := nostr.GeneratePrivateKey()
	now := time.Now()
	relay := newListRelay(t)
	ctx, _ := blastTestSetup(t, relay.url)
	pk, _ := nostr.GetPublicKey(sk)
	config.WhitelistedPubKeys = map[string]struct{}{pk: {}}

	vault := newTestStore(t)
	newer := signedList(t, sk, 3, now.Add(-time.Minute), nostr.Tags{{"p", hexid('1')}, {"p", hexid('2')}})
	if err := vault.Publish(ctx, *newer); err != nil {
		t.Fatal(err)
	}
	older := signedList(t, sk, 3, now.Add(-time.Hour), nostr.Tags{{"p", hexid('1')}})
	q := openBlastQueue(blastPendingFile)
	q.local = vault.Store
	q.items = []pendingBlast{queuedNow(older)}
	retryPendingOnce(ctx, q)

	if relay.received(older.ID) {
		t.Fatal("the older follow list was sent although the vault holds a newer one")
	}
	if s := q.snapshot(); len(s) != 0 {
		t.Fatalf("older list still queued: %+v", s)
	}
}

// No relay answered the check: one silence is not "nothing newer". The list
// is not sent, and stays queued for a later try.
func TestQueuedListNotSentWhenNoRelayAnswers(t *testing.T) {
	sk := nostr.GeneratePrivateKey()
	ctx, _ := blastTestSetup(t, deadRelayURL())
	pk, _ := nostr.GetPublicKey(sk)
	config.WhitelistedPubKeys = map[string]struct{}{pk: {}}

	var checks int
	prev := newerListOnRelays
	newerListOnRelays = func(context.Context, []string, *nostr.Event) (bool, int) { checks++; return false, 0 }
	t.Cleanup(func() { newerListOnRelays = prev })

	list := signedList(t, sk, 10063, time.Now().Add(-time.Hour), nostr.Tags{{"server", "https://b.example"}})
	q := openBlastQueue(blastPendingFile)
	q.items = []pendingBlast{queuedNow(list)}
	retryPendingOnce(ctx, q)

	if checks != 1 {
		t.Fatalf("relays asked %d times, want 1", checks)
	}
	s := q.snapshot()
	if len(s) != 1 || s[0].Attempts != 1 || s[0].NextAt <= time.Now().Unix() {
		t.Fatalf("list should stay queued with its next try pushed back: %+v", s)
	}
}

// The relay answered and holds nothing newer: the queued list goes out.
func TestQueuedListSentWhenNothingNewer(t *testing.T) {
	sk := nostr.GeneratePrivateKey()
	relay := newListRelay(t)
	ctx, _ := blastTestSetup(t, relay.url)
	pk, _ := nostr.GetPublicKey(sk)
	config.WhitelistedPubKeys = map[string]struct{}{pk: {}}

	list := signedList(t, sk, 10002, time.Now().Add(-time.Hour), relayTags("wss://only.example"))
	q := openBlastQueue(blastPendingFile)
	q.items = []pendingBlast{queuedNow(list)}
	retryPendingOnce(ctx, q)

	if !relay.received(list.ID) {
		t.Fatal("the list was not sent although no newer copy exists")
	}
	if s := q.snapshot(); len(s) != 0 {
		t.Fatalf("sent list still queued: %+v", s)
	}
}

// A note is not a list: no check, sent as before.
func TestQueuedNoteSkipsTheListCheck(t *testing.T) {
	sk := nostr.GeneratePrivateKey()
	relay := newListRelay(t)
	ctx, _ := blastTestSetup(t, relay.url)
	pk, _ := nostr.GetPublicKey(sk)
	config.WhitelistedPubKeys = map[string]struct{}{pk: {}}

	prev := newerListOnRelays
	newerListOnRelays = func(context.Context, []string, *nostr.Event) (bool, int) {
		t.Fatal("a note was checked as a list")
		return false, 0
	}
	t.Cleanup(func() { newerListOnRelays = prev })

	note := signedNote(t, sk, time.Now().Add(-time.Hour), "hello")
	q := openBlastQueue(blastPendingFile)
	q.items = []pendingBlast{queuedNow(note)}
	retryPendingOnce(ctx, q)
	if !relay.received(note.ID) {
		t.Fatal("note not sent")
	}
}

// uploadIDs runs the negentropy up-direction source for ids.
func uploadIDs(t *testing.T, s *outboxNegStore, ids ...string) []string {
	t.Helper()
	ch, err := s.QueryEvents(context.Background(), nostr.Filter{IDs: ids})
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for ev := range ch {
		got = append(got, ev.ID)
	}
	return got
}

// The owner sync uploads what the relay lacks. A list it lacks may be one it
// replaced with a newer copy: then ours is not uploaded.
func TestNegsyncDoesNotUploadAnOlderList(t *testing.T) {
	sk := nostr.GeneratePrivateKey()
	pk, _ := nostr.GetPublicKey(sk)
	setupSyncConfig(pk)
	prevPool := pool
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(func() { cancel(); pool = prevPool })
	pool = nostr.NewSimplePool(ctx)

	now := time.Now()
	older := signedList(t, sk, 10002, now.Add(-time.Hour), relayTags("wss://old.example"))
	newer := signedList(t, sk, 10002, now.Add(-time.Minute), relayTags("wss://new.example"))
	note := signedNote(t, sk, now.Add(-time.Hour), "a note")
	hasNewer := newListRelay(t, newer)
	empty := newListRelay(t)

	outbox := newTestStore(t)
	for _, ev := range []*nostr.Event{older, note} {
		if err := outbox.Publish(ctx, *ev); err != nil {
			t.Fatal(err)
		}
	}
	s := &outboxNegStore{outbox: outbox, tombs: newTestTombs(t)}

	if got := uploadIDs(t, s.uploadingTo(hasNewer.url), older.ID, note.ID); fmt.Sprint(got) != fmt.Sprint([]string{note.ID}) {
		t.Fatalf("relay with a newer list: uploaded %v, want only the note", got)
	}
	if got := uploadIDs(t, s.uploadingTo(deadRelayURL()), older.ID); len(got) != 0 {
		t.Fatalf("relay that never answered: uploaded %v, want nothing", got)
	}
	if got := uploadIDs(t, s, older.ID); len(got) != 0 {
		t.Fatalf("no relay to ask: uploaded %v, want nothing", got)
	}
	if got := uploadIDs(t, s.uploadingTo(empty.url), older.ID); len(got) != 1 {
		t.Fatalf("relay with no copy: uploaded %v, want the list", got)
	}
}

// A backup holding an older copy of a list than the vault must not replace
// it, and two copies in one backup keep only the newest.
func TestImportKeepsTheNewestList(t *testing.T) {
	db := newTestBackend(t, "import-lists")
	if err := db.Init(); err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	ctx := context.Background()
	sk := nostr.GeneratePrivateKey()
	pk, _ := nostr.GetPublicKey(sk)
	now := time.Now()

	current := signedList(t, sk, 3, now.Add(-time.Minute), nostr.Tags{{"p", hexid('1')}, {"p", hexid('2')}})
	if err := db.ReplaceEvent(ctx, current); err != nil {
		t.Fatal(err)
	}
	old := signedList(t, sk, 3, now.Add(-24*time.Hour), nostr.Tags{{"p", hexid('1')}})
	r1 := signedList(t, sk, 10002, now.Add(-2*time.Hour), relayTags("wss://a.example"))
	r2 := signedList(t, sk, 10002, now.Add(-time.Hour), relayTags("wss://b.example"))
	art1 := signedList(t, sk, 30023, now.Add(-2*time.Hour), nostr.Tags{{"d", "post"}})
	art2 := signedList(t, sk, 30023, now.Add(-time.Hour), nostr.Tags{{"d", "post"}})
	other := signedList(t, sk, 30023, now.Add(-3*time.Hour), nostr.Tags{{"d", "other"}})

	var lines strings.Builder
	for _, ev := range []*nostr.Event{old, r2, r1, art1, art2, other} {
		fmt.Fprintln(&lines, ev)
	}
	if err := importDB(ctx, db, strings.NewReader(lines.String())); err != nil {
		t.Fatal(err)
	}

	// Read every stored copy: a store query with kinds caps a replaceable
	// kind at one result, which would hide a second copy.
	ids := func(f nostr.Filter) []string {
		ch, err := db.QueryEvents(ctx, nostr.Filter{Authors: []string{pk}})
		if err != nil {
			t.Fatal(err)
		}
		var out []string
		for ev := range ch {
			if f.Kinds[0] == ev.Kind && (f.Tags == nil || f.Tags["d"][0] == ev.Tags.GetD()) {
				out = append(out, ev.ID)
			}
		}
		return out
	}
	if got := ids(nostr.Filter{Kinds: []int{3}}); len(got) != 1 || got[0] != current.ID {
		t.Fatalf("kind 3 after import = %v, want only the vault's newer list", got)
	}
	if got := ids(nostr.Filter{Kinds: []int{10002}}); len(got) != 1 || got[0] != r2.ID {
		t.Fatalf("kind 10002 after import = %v, want only the newest", got)
	}
	if got := ids(nostr.Filter{Kinds: []int{30023}, Tags: nostr.TagMap{"d": {"post"}}}); len(got) != 1 || got[0] != art2.ID {
		t.Fatalf("30023 d=post after import = %v, want only the newest", got)
	}
	if got := ids(nostr.Filter{Kinds: []int{30023}, Tags: nostr.TagMap{"d": {"other"}}}); len(got) != 1 {
		t.Fatalf("30023 d=other after import = %v, want it kept", got)
	}
}
