//go:build !cshared

package main

import (
	"context"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/fiatjaf/eventstore"
	"github.com/fiatjaf/khatru"
	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/pkg/wot"
)

// deletionBackends runs a test against every database engine this platform
// builds, since isDeleted relies on each engine's tag index.
func deletionBackends(t *testing.T, run func(t *testing.T, db DBBackend)) {
	backends := map[string]func(path string) DBBackend{"badger": newBadgerBackend}
	if lmdbFactory != nil {
		backends["lmdb"] = lmdbFactory
	}
	for name, factory := range backends {
		t.Run(name, func(t *testing.T) {
			db := factory(t.TempDir() + "/db")
			if err := db.Init(); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(db.Close)
			run(t, db)
		})
	}
}

type testKey struct{ sk, pk string }

func newTestKey(t *testing.T) testKey {
	t.Helper()
	sk := nostr.GeneratePrivateKey()
	pk, err := nostr.GetPublicKey(sk)
	if err != nil {
		t.Fatal(err)
	}
	return testKey{sk, pk}
}

func (k testKey) sign(t *testing.T, ev nostr.Event) nostr.Event {
	t.Helper()
	if ev.CreatedAt == 0 {
		ev.CreatedAt = nostr.Now()
	}
	if ev.Tags == nil {
		ev.Tags = nostr.Tags{}
	}
	if err := ev.Sign(k.sk); err != nil {
		t.Fatal(err)
	}
	return ev
}

// startDeletionRelay wires a relay the way initRelays wires each of the four
// stores: same query path (enableSearch), same deletion outcome and the same
// re-publish guard.
func startDeletionRelay(t *testing.T, db DBBackend) *nostr.Relay {
	t.Helper()
	rl := khatru.NewRelay()
	rl.RejectEvent = append(rl.RejectEvent, MustNotBeDeleted(db))
	rl.StoreEvent = append(rl.StoreEvent, db.SaveEvent)
	enableSearch(rl, db)
	rl.DeleteEvent = append(rl.DeleteEvent, db.DeleteEvent)
	rl.OverwriteDeletionOutcome = append(rl.OverwriteDeletionOutcome, OwnerCanDeleteAnyEvent)
	rl.ReplaceEvent = append(rl.ReplaceEvent, db.ReplaceEvent)

	srv := httptest.NewServer(rl)
	t.Cleanup(srv.Close)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := nostr.RelayConnect(ctx, "ws"+strings.TrimPrefix(srv.URL, "http"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	return conn
}

func publish(t *testing.T, r *nostr.Relay, ev nostr.Event) error {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return r.Publish(ctx, ev)
}

func stored(t *testing.T, db DBBackend, id string) bool {
	t.Helper()
	ch, err := db.QueryEvents(context.Background(), nostr.Filter{IDs: []string{id}})
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for range ch {
		found = true
	}
	return found
}

func TestOwnerCanDeleteAnyEvent(t *testing.T) {
	deletionBackends(t, func(t *testing.T, db DBBackend) {
		owner, stranger, other := newTestKey(t), newTestKey(t), newTestKey(t)
		saved := config
		t.Cleanup(func() { config = saved })
		config = Config{OwnerPubKey: owner.pk}
		r := startDeletionRelay(t, db)

		note := stranger.sign(t, nostr.Event{Kind: nostr.KindTextNote, Content: "spam"})
		if err := publish(t, r, note); err != nil {
			t.Fatal(err)
		}
		del := func(k testKey, tag nostr.Tag) nostr.Event {
			return k.sign(t, nostr.Event{Kind: nostr.KindDeletion, Tags: nostr.Tags{tag}})
		}

		// A third party still cannot delete somebody else's event.
		if err := publish(t, r, del(other, nostr.Tag{"e", note.ID})); err == nil || !strings.Contains(err.Error(), "not the author") {
			t.Fatalf("stranger's delete request: err = %v, want 'not the author'", err)
		}
		if !stored(t, db, note.ID) {
			t.Fatal("note was deleted by a non-author, non-owner")
		}

		// The owner can.
		ownerDel := del(owner, nostr.Tag{"e", note.ID})
		if err := publish(t, r, ownerDel); err != nil {
			t.Fatalf("owner's delete request rejected: %v", err)
		}
		if stored(t, db, note.ID) {
			t.Fatal("note survived the owner's delete request")
		}
		if !stored(t, db, ownerDel.ID) {
			t.Fatal("owner's delete request was not stored, so the deletion cannot stick")
		}

		// And it stays deleted.
		if err := publish(t, r, note); err == nil || !strings.Contains(err.Error(), "deleted") {
			t.Fatalf("re-publish of a deleted note: err = %v, want 'deleted'", err)
		}

		// Authors still delete their own events.
		own := other.sign(t, nostr.Event{Kind: nostr.KindTextNote, Content: "mine"})
		if err := publish(t, r, own); err != nil {
			t.Fatal(err)
		}
		if err := publish(t, r, del(other, nostr.Tag{"e", own.ID})); err != nil {
			t.Fatalf("author's own delete request rejected: %v", err)
		}
		if stored(t, db, own.ID) {
			t.Fatal("author could not delete their own note")
		}

		// Addressable events are deleted by address, and only the versions
		// that existed when the request was made.
		base := nostr.Now() - 100
		article := stranger.sign(t, nostr.Event{Kind: 30023, CreatedAt: base, Tags: nostr.Tags{{"d", "x"}}, Content: "v1"})
		if err := publish(t, r, article); err != nil {
			t.Fatal(err)
		}
		addr := "30023:" + stranger.pk + ":x"
		aDel := owner.sign(t, nostr.Event{Kind: nostr.KindDeletion, CreatedAt: base + 10, Tags: nostr.Tags{{"a", addr}}})
		if err := publish(t, r, aDel); err != nil {
			t.Fatalf("owner's address delete rejected: %v", err)
		}
		if stored(t, db, article.ID) {
			t.Fatal("article survived the owner's address delete")
		}
		if err := publish(t, r, article); err == nil {
			t.Fatal("re-publish of a deleted article version was accepted")
		}
		newer := stranger.sign(t, nostr.Event{Kind: 30023, CreatedAt: base + 20, Tags: nostr.Tags{{"d", "x"}}, Content: "v2"})
		if err := publish(t, r, newer); err != nil {
			t.Fatalf("a version written after the delete request was rejected: %v", err)
		}
	})
}

// The negentropy sync stores write straight to the database, bypassing the
// relay's policies, so they need their own check — otherwise the next sync
// round brings a deleted event straight back.
func TestNegStoresSkipDeletedEvents(t *testing.T) {
	owner := hexid('0')
	author := hexid('1')
	setupSyncConfig(owner)
	config.OwnerPubKey = owner
	wot.MarkReady(wot.NewCycle(), stubWot{allow: true})
	ctx := context.Background()

	reply := nostr.Event{ID: hexid('a'), PubKey: author, Kind: nostr.KindTextNote, CreatedAt: nostr.Now(), Tags: nostr.Tags{{"p", owner}}}
	ownerNote := nostr.Event{ID: hexid('b'), PubKey: owner, Kind: nostr.KindTextNote, CreatedAt: nostr.Now(), Tags: nostr.Tags{}}
	deletion := func(id string, target string) *nostr.Event {
		return &nostr.Event{ID: id, PubKey: owner, Kind: nostr.KindDeletion, CreatedAt: nostr.Now(), Tags: nostr.Tags{{"e", target}}}
	}

	inbox, chat, outbox := newTestStore(t), newTestStore(t), newTestStore(t)
	tombs := newTestTombs(t)
	in := &inboxNegStore{inbox: inbox, chat: chat, tombs: tombs, rejects: &tempRejects{}, notifier: &batchNotifier{}}
	out := &outboxNegStore{outbox: outbox, tombs: tombs}

	if err := inbox.Store.SaveEvent(ctx, deletion(hexid('c'), reply.ID)); err != nil {
		t.Fatal(err)
	}
	if err := outbox.Store.SaveEvent(ctx, deletion(hexid('d'), ownerNote.ID)); err != nil {
		t.Fatal(err)
	}

	if err := in.Publish(ctx, reply); err != nil {
		t.Fatal(err)
	}
	if err := out.Publish(ctx, ownerNote); err != nil {
		t.Fatal(err)
	}
	for name, c := range map[string]struct {
		store eventstore.RelayWrapper
		id    string
	}{"inbox": {inbox, reply.ID}, "outbox": {outbox, ownerNote.ID}} {
		if isDuplicate(ctx, c.store, &nostr.Event{ID: c.id, CreatedAt: reply.CreatedAt}) {
			t.Errorf("%s: deleted event was stored again by sync", name)
		}
		if !tombs.Has(c.id) {
			t.Errorf("%s: deleted event not tombstoned, so sync re-offers it every round", name)
		}
	}

	// Positive control: the same event with no delete request is stored.
	fresh := reply
	fresh.ID = hexid('e')
	if err := in.Publish(ctx, fresh); err != nil {
		t.Fatal(err)
	}
	if !isDuplicate(ctx, inbox, &fresh) {
		t.Fatal("control event was not stored — the test cannot tell a skip from a broken store")
	}
}

// The owner's delete requests must reach the chat and inbox stores (or the
// deletion is not stored and does not stick), and need no AUTH round trip.
// Anyone else's delete request, and the owner's other events, are unaffected.
func TestOwnerDeleteRequestPassesStorePolicies(t *testing.T) {
	owner, stranger := hexid('0'), hexid('1')
	saved := config
	t.Cleanup(func() { config = saved })
	config = Config{
		OwnerPubKey:        owner,
		WhitelistedPubKeys: map[string]struct{}{owner: {}},
		BlacklistedPubKeys: map[string]struct{}{},
	}
	ctx := context.Background() // not authenticated
	ev := func(pk string, kind int) *nostr.Event {
		return &nostr.Event{ID: hexid('a'), PubKey: pk, Kind: kind, CreatedAt: nostr.Now(), Tags: nostr.Tags{{"e", hexid('b')}}}
	}
	policies := map[string]func(context.Context, *nostr.Event) (bool, string){
		"MustNotBeBlacklistedToPost": MustNotBeBlacklistedToPost,
		"EventMustBeChatRelated":     EventMustBeChatRelated,
		"MustTagWhitelistedPubKey":   MustTagWhitelistedPubKey,
	}
	for name, policy := range policies {
		if reject, msg := policy(ctx, ev(owner, nostr.KindDeletion)); reject {
			t.Errorf("%s rejected the owner's delete request: %s", name, msg)
		}
		if reject, _ := policy(ctx, ev(stranger, nostr.KindDeletion)); !reject {
			t.Errorf("%s accepted a stranger's unauthenticated delete request", name)
		}
		if reject, _ := policy(ctx, ev(owner, nostr.KindTextNote)); !reject {
			t.Errorf("%s accepted the owner's unauthenticated kind 1 — the bypass is wider than delete requests", name)
		}
	}
}
