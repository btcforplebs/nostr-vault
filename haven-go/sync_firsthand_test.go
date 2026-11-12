package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/fiatjaf/eventstore"
	"github.com/fiatjaf/khatru"
	"github.com/nbd-wtf/go-nostr"
)

// Device sync rework, steps 1 and 2 (RESEARCH/NV_DEVICE_SYNC_MAP_2026_11_12.md
// §4.3, §4.5): a signed delete is final in the blast queue and the feed
// cache, and only first-hand writes are published.

func signedDelete(t *testing.T, sk string, target *nostr.Event) *nostr.Event {
	t.Helper()
	pk, _ := nostr.GetPublicKey(sk)
	del := &nostr.Event{PubKey: pk, Kind: nostr.KindDeletion, CreatedAt: target.CreatedAt + 1, Tags: nostr.Tags{{"e", target.ID}}}
	del.Sign(sk)
	return del
}

// countingRelay accepts every note and counts the ones it took.
func countingRelay(t *testing.T) (string, *atomic.Int32) {
	url, got, _ := recordingRelay(t)
	return url, got
}

// recordingRelay is countingRelay that also keeps the ids it took.
func recordingRelay(t *testing.T) (string, *atomic.Int32, *sync.Map) {
	var got atomic.Int32
	var ids sync.Map
	r := khatru.NewRelay()
	r.StoreEvent = append(r.StoreEvent, func(_ context.Context, ev *nostr.Event) error {
		ids.Store(ev.ID, true)
		got.Add(1)
		return nil
	})
	srv := httptest.NewServer(r)
	t.Cleanup(srv.Close)
	return "ws" + strings.TrimPrefix(srv.URL, "http"), &got, &ids
}

// A note queued for a later blast and deleted since is never sent: the
// retry queue checks the outbox's signed deletes and drops it.
func TestQueuedBlastOfADeletedNoteIsDropped(t *testing.T) {
	url, got := countingRelay(t)
	ctx, sk := blastTestSetup(t, url)
	db := withOutbox(t)
	note := &nostr.Event{Kind: 1, CreatedAt: nostr.Now() - 10, Content: "deleted later"}
	note.Sign(sk)
	if err := db.SaveEvent(ctx, signedDelete(t, sk, note)); err != nil {
		t.Fatal(err)
	}
	q := openBlastQueue(blastPendingFile)
	q.local = db
	q.items = []pendingBlast{queuedNow(note)}
	retryPendingOnce(ctx, q)
	if n := got.Load(); n != 0 {
		t.Fatalf("a deleted note was sent %d time(s)", n)
	}
	if len(q.snapshot()) != 0 {
		t.Fatal("a deleted note stays in the blast queue")
	}
}

// A note deleted while it waited in the blast pool is not sent either.
func TestBlastPoolSkipsADeletedNote(t *testing.T) {
	url, got, ids := recordingRelay(t)
	ctx, sk := blastTestSetup(t, url)
	db := withOutbox(t)
	ctx, cancel := context.WithCancel(ctx)
	note := &nostr.Event{Kind: 1, CreatedAt: nostr.Now() - 10, Content: "deleted before its turn"}
	note.Sign(sk)
	if err := db.SaveEvent(ctx, signedDelete(t, sk, note)); err != nil {
		t.Fatal(err)
	}
	q := openBlastQueue(blastPendingFile)
	q.local = db
	send, done := newBlastSender(ctx, q)
	t.Cleanup(func() { cancel(); <-done })
	keep := &nostr.Event{Kind: 1, CreatedAt: nostr.Now(), Content: "kept"}
	keep.Sign(sk)
	send(note)
	send(keep)
	deadline := time.Now().Add(5 * time.Second)
	for got.Load() < 1 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	time.Sleep(300 * time.Millisecond) // room for the deleted one to arrive, if it were sent
	if _, ok := ids.Load(note.ID); ok {
		t.Fatal("a note deleted while it waited in the pool was sent")
	}
	if _, ok := ids.Load(keep.ID); !ok {
		t.Fatal("the note that was not deleted was not sent")
	}
}

// The feed cache honours a follow's signed delete: the delete removes the
// note, and the note pulled again from another relay is refused.
func TestFeedCacheHonoursSignedDeletes(t *testing.T) {
	saved := feedDB
	t.Cleanup(func() { feedDB = saved })
	db := newTestBackend(t, "feed")
	if err := db.Init(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	feedDB = db
	ctx := context.Background()
	sk := nostr.GeneratePrivateKey()
	pk, _ := nostr.GetPublicKey(sk)
	store := &feedNegStore{feed: eventstore.RelayWrapper{Store: db}, follows: map[string]struct{}{pk: {}}}

	note := &nostr.Event{PubKey: pk, Kind: 1, CreatedAt: nostr.Now() - 60, Content: "a follow's note"}
	note.Sign(sk)
	if err := store.Publish(ctx, *note); err != nil {
		t.Fatal(err)
	}
	if !storeHolds(ctx, db, note.ID) {
		t.Fatal("test setup: note not stored")
	}
	if err := store.Publish(ctx, *signedDelete(t, sk, note)); err != nil {
		t.Fatal(err)
	}
	if storeHolds(ctx, db, note.ID) {
		t.Fatal("the follow's delete did not remove the note from the feed cache")
	}
	if err := store.Publish(ctx, *note); err != nil {
		t.Fatal(err)
	}
	if storeHolds(ctx, db, note.ID) {
		t.Fatal("a deleted note came back into the feed cache")
	}
	// Someone else's delete does nothing.
	other := nostr.GeneratePrivateKey()
	keep := &nostr.Event{PubKey: pk, Kind: 1, CreatedAt: nostr.Now() - 30, Content: "kept"}
	keep.Sign(sk)
	_ = store.Publish(ctx, *keep)
	_ = store.Publish(ctx, *signedDelete(t, other, keep))
	if !storeHolds(ctx, db, keep.ID) {
		t.Fatal("a stranger's delete removed a follow's note")
	}
	if !slicesContains(feedPullKinds(), nostr.KindDeletion) {
		t.Fatal("feed sync does not pull follows' deletes")
	}
}

func slicesContains(s []int, v int) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}

// Only first-hand writes are published: what the iPhone's own-device port
// (another of the owner's devices) writes is stored, not blasted, like the
// mesh door and ?pulled=1.
func TestWritesFromAnotherOwnDeviceAreNotBlasted(t *testing.T) {
	sk, pk := withOwner(t)
	db := withOutbox(t)
	relay := khatru.NewRelay()
	var mu sync.Mutex
	blasted := map[string]bool{}
	wireOutboxWrites(relay, db, func(ev *nostr.Event) { mu.Lock(); blasted[ev.ID] = true; mu.Unlock() })

	ownPort := httptest.NewRequest(http.MethodGet, "/", nil)
	ownPort = ownPort.WithContext(context.WithValue(ownPort.Context(), meshOwnPortKey{}, true))
	ownPortCtx := context.WithValue(context.Background(), 0, &khatru.WebSocket{Request: ownPort})

	fromDevice := &nostr.Event{PubKey: pk, Kind: 1, CreatedAt: nostr.Now(), Content: "from my other phone"}
	fromDevice.Sign(sk)
	firstHand := &nostr.Event{PubKey: pk, Kind: 1, CreatedAt: nostr.Now(), Content: "written here"}
	firstHand.Sign(sk)
	if _, err := relay.AddEvent(ownPortCtx, fromDevice); err != nil {
		t.Fatal(err)
	}
	if _, err := relay.AddEvent(connCtx("/"), firstHand); err != nil {
		t.Fatal(err)
	}
	if blasted[fromDevice.ID] {
		t.Error("a write from the own-device port was blasted")
	}
	if !blasted[firstHand.ID] {
		t.Error("a first-hand write was not blasted")
	}
}

// What this vault sends to another of the owner's devices (the Mac relay:
// owner catch-up uploads, the blast list) carries the second-hand mark;
// public relays are dialled as they are.
func TestOwnDeviceWritesCarryTheMark(t *testing.T) {
	saved := config.MacRelayURL
	t.Cleanup(func() { config.MacRelayURL = saved })
	config.MacRelayURL = "ws://192.168.4.20:3355/"
	for in, want := range map[string]string{
		"ws://192.168.4.20:3355":          "ws://192.168.4.20:3355?pulled=1",
		"ws://192.168.4.20:3355/":         "ws://192.168.4.20:3355/?pulled=1",
		"ws://192.168.4.20:3355?pulled=1": "ws://192.168.4.20:3355?pulled=1",
		"wss://relay.damus.io":            "wss://relay.damus.io",
		"ws://192.168.4.20:3355/inbox":    "ws://192.168.4.20:3355/inbox",
	} {
		if got := ownDeviceWriteURL(in); got != want {
			t.Errorf("ownDeviceWriteURL(%q) = %q, want %q", in, got, want)
		}
	}
}
