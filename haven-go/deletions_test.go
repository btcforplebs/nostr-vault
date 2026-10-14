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
	backends := map[string]func(t *testing.T) DBBackend{
		strings.ToLower(fallbackBackendName): func(t *testing.T) DBBackend { return newTestBackend(t, "db") },
	}
	if lmdbFactory != nil {
		backends["lmdb"] = func(t *testing.T) DBBackend { return lmdbFactory(t.TempDir() + "/db") }
	}
	for name, factory := range backends {
		t.Run(name, func(t *testing.T) {
			db := factory(t)
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
	skipWithoutSockets(t)
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
	skipWithoutFS(t)
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

// importedDeletePath is one way a delete request from another of the owner's
// devices reaches the outbox store without passing through khatru's
// websocket pipeline.
type importedDeletePath struct {
	name  string
	apply func(t *testing.T, outbox eventstore.RelayWrapper, ev nostr.Event)
}

func importedDeletePaths(t *testing.T) []importedDeletePath {
	return []importedDeletePath{
		{"owner catch-up", func(t *testing.T, outbox eventstore.RelayWrapper, ev nostr.Event) {
			processOwnerEvent(context.Background(), nostr.RelayEvent{Event: &ev}, outbox)
		}},
		{"outbox negentropy", func(t *testing.T, outbox eventstore.RelayWrapper, ev nostr.Event) {
			s := &outboxNegStore{outbox: outbox, tombs: newTestTombs(t)}
			if err := s.Publish(context.Background(), ev); err != nil {
				t.Fatal(err)
			}
		}},
	}
}

// A kind 5 written straight to the outbox store (owner catch-up, outbox
// negentropy) must remove the events it targets, exactly as khatru does for
// a kind 5 received over a websocket. Before this, the request was stored but
// the post stayed, so a post deleted on the phone lived on in the Mac and
// Android vaults.
func TestImportedDeleteRequestRemovesTargets(t *testing.T) {
	owner, cowner := newTestKey(t), newTestKey(t)
	saved := config
	t.Cleanup(func() { config = saved })
	setupSyncConfig(owner.pk)
	config.OwnerPubKey = owner.pk
	config.WhitelistedPubKeys[cowner.pk] = struct{}{}
	ctx := context.Background()

	del := func(k testKey, tags ...nostr.Tag) nostr.Event {
		return k.sign(t, nostr.Event{Kind: nostr.KindDeletion, Tags: tags})
	}

	for _, path := range importedDeletePaths(t) {
		t.Run(path.name, func(t *testing.T) {
			deletionBackends(t, func(t *testing.T, db DBBackend) {
				outbox := eventstore.RelayWrapper{Store: db}
				save := func(ev nostr.Event) {
					if err := db.SaveEvent(ctx, &ev); err != nil {
						t.Fatal(err)
					}
				}

				// Own post, then its delete request: post gone, request kept.
				post := owner.sign(t, nostr.Event{Kind: nostr.KindTextNote, Content: "vault delete test"})
				kept := owner.sign(t, nostr.Event{Kind: nostr.KindTextNote, Content: "stays"})
				save(post)
				save(kept)
				req := del(owner, nostr.Tag{"e", post.ID})
				path.apply(t, outbox, req)
				if stored(t, db, post.ID) {
					t.Fatal("post survived its imported delete request")
				}
				if !stored(t, db, req.ID) {
					t.Fatal("delete request was not stored, so a re-import of the post would not be blocked")
				}
				if !stored(t, db, kept.ID) {
					t.Fatal("an untargeted post was removed")
				}

				// Request before its target: the post must never be stored.
				early := owner.sign(t, nostr.Event{Kind: nostr.KindTextNote, Content: "deleted before it arrived"})
				path.apply(t, outbox, del(owner, nostr.Tag{"e", early.ID}))
				path.apply(t, outbox, early)
				if stored(t, db, early.ID) {
					t.Fatal("post arriving after its delete request was stored")
				}

				// Only the author or the relay owner may delete. A co-whitelisted
				// key cannot remove the owner's post; the owner can remove theirs.
				ownerPost := owner.sign(t, nostr.Event{Kind: nostr.KindTextNote, Content: "owner's"})
				coPost := cowner.sign(t, nostr.Event{Kind: nostr.KindTextNote, Content: "co-owner's"})
				save(ownerPost)
				save(coPost)
				path.apply(t, outbox, del(cowner, nostr.Tag{"e", ownerPost.ID}))
				if !stored(t, db, ownerPost.ID) {
					t.Fatal("a non-author, non-owner delete request removed the owner's post")
				}
				path.apply(t, outbox, del(owner, nostr.Tag{"e", coPost.ID}))
				if stored(t, db, coPost.ID) {
					t.Fatal("the owner's delete request did not remove a co-whitelisted author's post")
				}

				// Addressable events go by "a", and only versions that existed
				// when the request was made.
				base := nostr.Now() - 100
				v1 := owner.sign(t, nostr.Event{Kind: 30023, CreatedAt: base, Tags: nostr.Tags{{"d", "x"}}, Content: "v1"})
				v2 := owner.sign(t, nostr.Event{Kind: 30023, CreatedAt: base + 20, Tags: nostr.Tags{{"d", "x"}}, Content: "v2"})
				save(v1)
				addr := "30023:" + owner.pk + ":x"
				path.apply(t, outbox, owner.sign(t, nostr.Event{Kind: nostr.KindDeletion, CreatedAt: base + 10, Tags: nostr.Tags{{"a", addr}}}))
				if stored(t, db, v1.ID) {
					t.Fatal("article version survived an imported address delete")
				}
				path.apply(t, outbox, v2)
				if !stored(t, db, v2.ID) {
					t.Fatal("a version written after the delete request was kept out")
				}
			})
		})
	}
}

// Vaults filled before imports applied deletions hold kind 5s whose targets
// were never removed. The startup sweep applies them once.
func TestSweepDeleteRequests(t *testing.T) {
	owner, stranger := newTestKey(t), newTestKey(t)
	saved := config
	t.Cleanup(func() { config = saved })
	setupSyncConfig(owner.pk)
	config.OwnerPubKey = owner.pk
	ctx := context.Background()

	deletionBackends(t, func(t *testing.T, db DBBackend) {
		save := func(ev nostr.Event) {
			if err := db.SaveEvent(ctx, &ev); err != nil {
				t.Fatal(err)
			}
		}
		post := owner.sign(t, nostr.Event{Kind: nostr.KindTextNote, Content: "old delete, target kept"})
		kept := owner.sign(t, nostr.Event{Kind: nostr.KindTextNote, Content: "stays"})
		save(post)
		save(kept)
		save(owner.sign(t, nostr.Event{Kind: nostr.KindDeletion, Tags: nostr.Tags{{"e", post.ID}}}))
		// A stranger's stored request (not whitelisted) is not swept.
		save(stranger.sign(t, nostr.Event{Kind: nostr.KindDeletion, Tags: nostr.Tags{{"e", kept.ID}}}))

		sweepDeleteRequests(ctx, db)

		if stored(t, db, post.ID) {
			t.Fatal("sweep left the target of a stored delete request in place")
		}
		if !stored(t, db, kept.ID) {
			t.Fatal("sweep removed a post only a stranger asked to delete")
		}
	})
}

// The startup import (importOwnerNotes) writes to the outbox store directly
// too, so a delete request it pulls from a seed relay must remove its target
// as well. The target is stored beforehand, so only the import's own
// deletion step can remove it — not the isDeleted re-import guard.
func TestImportOwnerNotesAppliesDeleteRequests(t *testing.T) {
	skipWithoutSockets(t)
	owner := newTestKey(t)
	savedCfg, savedDB, savedPool, savedReach := config, outboxDB, pool, reachableImportRelays.Load()
	t.Cleanup(func() {
		config, outboxDB, pool = savedCfg, savedDB, savedPool
		reachableImportRelays.Store(savedReach)
	})
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)

	setupSyncConfig(owner.pk)
	config.OwnerPubKey = owner.pk
	config.ImportStartDate = time.Now().AddDate(0, 0, -1).Format(layout)
	config.ImportOwnerNotesFetchTimeoutSeconds = 5
	reachableImportRelays.Store(nil)
	pool = nostr.NewSimplePool(ctx)

	deletionBackends(t, func(t *testing.T, db DBBackend) {
		seed := newFakeMac(t, false, 0)
		config.ImportSeedRelays = []string{seed.url}
		outboxDB = db
		post := owner.sign(t, nostr.Event{Kind: nostr.KindTextNote, Content: "deleted on another device"})
		if err := db.SaveEvent(ctx, &post); err != nil {
			t.Fatal(err)
		}
		kept := owner.sign(t, nostr.Event{Kind: nostr.KindTextNote, Content: "stays"})
		req := owner.sign(t, nostr.Event{Kind: nostr.KindDeletion, Tags: nostr.Tags{{"e", post.ID}}})
		for _, ev := range []nostr.Event{kept, req} {
			if err := seed.store.Store.SaveEvent(ctx, &ev); err != nil {
				t.Fatal(err)
			}
		}

		importOwnerNotes(ctx)

		// Positive control: the import ran and stored what the relay served.
		if !stored(t, db, kept.ID) || !stored(t, db, req.ID) {
			t.Fatal("import stored nothing — the test cannot tell a skipped deletion from a broken import")
		}
		if stored(t, db, post.ID) {
			t.Fatal("post survived a delete request pulled by the startup import")
		}
	})
}
