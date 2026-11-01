package main

import (
	"context"
	"slices"
	"testing"
	"time"

	"github.com/barrydeen/haven/pkg/wot"
	"github.com/nbd-wtf/go-nostr"
)

func relayList(pk string, at nostr.Timestamp, kind int, tags ...nostr.Tag) *nostr.Event {
	return &nostr.Event{PubKey: pk, Kind: kind, CreatedAt: at, Tags: tags}
}

// The Nostr Vault account's real 10002 against the iPhone 18's shared set:
// only its own read relays that the shared set lacks are added, write-only
// relays are not, and 10050 relays follow.
func TestPickAccountInboxRelays(t *testing.T) {
	nv, logen := hexid('b'), hexid('a')
	shared := []string{"wss://relay.primal.net", "wss://relay.snort.social", "wss://relay.nos.social",
		"wss://logen.btcforplebs.com/inbox", "wss://relay.damus.io", "wss://relay.btcforplebs.com", "wss://nostr.wine"}
	lists := map[string]map[int]*nostr.Event{
		nv: {
			nostr.KindRelayListMetadata: relayList(nv, 1, nostr.KindRelayListMetadata,
				nostr.Tag{"r", "wss://relay.primal.net"},
				nostr.Tag{"r", "wss://relay.damus.io/"},
				nostr.Tag{"r", "wss://nostr-pub.wellorder.net"},
				nostr.Tag{"r", "wss://write.only.example", "write"},
				nostr.Tag{"r", "wss://profiles.nostrver.se", "read"},
				nostr.Tag{"r", "ws://127.0.0.1:4869"},
				nostr.Tag{"r", "wss://abc.onion"},
				nostr.Tag{"r", "wss://NOSTR.mom"}),
			nostr.KindDMRelayList: relayList(nv, 1, nostr.KindDMRelayList,
				nostr.Tag{"relay", "wss://nostr-pub.wellorder.net/"},
				nostr.Tag{"relay", "wss://dm.example"}),
		},
		logen: {
			nostr.KindRelayListMetadata: relayList(logen, 1, nostr.KindRelayListMetadata,
				nostr.Tag{"r", "wss://nostr-pub.wellorder.net"},
				nostr.Tag{"r", "wss://logen.example"}),
		},
	}
	got := pickAccountInboxRelays([]string{logen, nv}, lists, shared)
	want := []string{"wss://nostr-pub.wellorder.net", "wss://logen.example",
		"wss://profiles.nostrver.se", "wss://nostr.mom", "wss://dm.example"}
	if !slices.Equal(got, want) {
		t.Fatalf("got %v\nwant %v", got, want)
	}
}

func TestPickAccountInboxRelaysCaps(t *testing.T) {
	var accounts []string
	lists := map[string]map[int]*nostr.Event{}
	for i := range 5 {
		a := hexid(byte('a' + i))
		accounts = append(accounts, a)
		var tags nostr.Tags
		for j := range 9 {
			tags = append(tags, nostr.Tag{"r", "wss://r" + string(rune('a'+i)) + string(rune('0'+j)) + ".example"})
		}
		lists[a] = map[int]*nostr.Event{nostr.KindRelayListMetadata: relayList(a, 1, nostr.KindRelayListMetadata, tags...)}
	}
	got := pickAccountInboxRelays(accounts, lists, nil)
	if len(got) != maxAccountInboxRelays {
		t.Fatalf("got %d relays, want the %d cap", len(got), maxAccountInboxRelays)
	}
	if got[maxInboxRelaysPerAccount] != "wss://rb0.example" {
		t.Fatalf("account a took more than %d: %v", maxInboxRelaysPerAccount, got)
	}
}

// Only the newest list per account and kind counts.
func TestNewestRelayListsFromStore(t *testing.T) {
	skipWithoutFS(t)
	nv := hexid('b')
	db := newTestBackend(t, "outbox")
	if err := db.Init(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	ctx := context.Background()
	old := relayList(nv, 1, nostr.KindRelayListMetadata, nostr.Tag{"r", "wss://old.example"})
	old.ID = hexid('1')
	cur := relayList(nv, 2, nostr.KindRelayListMetadata, nostr.Tag{"r", "wss://new.example"})
	cur.ID = hexid('2')
	for _, ev := range []*nostr.Event{old, cur} {
		if err := db.SaveEvent(ctx, ev); err != nil {
			t.Fatal(err)
		}
	}
	got := inboxRelaysOf(newestRelayLists(ctx, db, []string{nv})[nv])
	if !slices.Equal(got, []string{"wss://new.example"}) {
		t.Fatalf("got %v, want the newest list", got)
	}
}

// M's real note (👌, two nostr: mentions, p-tags the Nostr Vault account,
// not the owner) sits only on a relay the Nostr Vault account lists. It
// reaches the inbox once over repeated rounds, and with the lists stored
// locally no extra socket is dialled to find them.
func TestAccountRelayBringsMNote(t *testing.T) {
	skipWithoutSockets(t)
	skipWithoutFS(t)
	ownerSK, nvSK, mSK := nostr.GeneratePrivateKey(), nostr.GeneratePrivateKey(), nostr.GeneratePrivateKey()
	owner, _ := nostr.GetPublicKey(ownerSK)
	nv, _ := nostr.GetPublicKey(nvSK)
	feather := hexid('f')

	seed := newFakeMac(t, false, 0)
	accountOnly := newFakeMac(t, false, 0)

	oldConfig, oldPool, oldOutbox, oldReachable, oldAllowed := config, pool, outboxDB, reachableImportRelays.Load(), accountRelayAllowed
	t.Cleanup(func() {
		config, pool, outboxDB, accountRelayAllowed = oldConfig, oldPool, oldOutbox, oldAllowed
		reachableImportRelays.Store(oldReachable)
	})
	setupSyncConfig(owner)
	config.WhitelistedPubKeys[nv] = struct{}{}
	config.ImportSeedRelays = []string{seed.url}
	reachableImportRelays.Store(nil)
	accountRelayAllowed = func(string) bool { return true }
	wot.MarkReady(wot.NewCycle(), stubWot{allow: true})

	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	pool = nostr.NewSimplePool(ctx)

	db := newTestBackend(t, "outbox")
	if err := db.Init(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	outboxDB = db
	list := nostr.Event{Kind: nostr.KindRelayListMetadata, CreatedAt: nostr.Now(),
		Tags: nostr.Tags{{"r", seed.url}, {"r", accountOnly.url}}}
	if err := list.Sign(nvSK); err != nil {
		t.Fatal(err)
	}
	if err := db.SaveEvent(ctx, &list); err != nil {
		t.Fatal(err)
	}

	note := nostr.Event{Kind: nostr.KindTextNote, CreatedAt: nostr.Now(),
		Tags:    nostr.Tags{{"e", hexid('9'), "", "root", hexid('8')}, {"p", hexid('8')}, {"p", feather}, {"p", nv}, {"client", "Nostrich"}},
		Content: "nostr:npub1r7u5wcxpv0fknn486uarrlset92caxntmwn22nvw2fjan630m03stxw3t3 and nostr:npub1fa05cayzx9xze32d2nhxnp7vhf42mkvpf9zr8xa9keq35tlrps5q7k0z97 👌"}
	if err := note.Sign(mSK); err != nil {
		t.Fatal(err)
	}
	if err := accountOnly.store.Store.SaveEvent(ctx, &note); err != nil {
		t.Fatal(err)
	}

	before := inboxRelays()
	if slices.Contains(before, accountOnly.url) {
		t.Fatal("the shared set already has the account relay")
	}
	relays := withAccountInboxRelays(ctx, before)
	// The owner has no list stored, so it is looked up on the seed relay
	// (already open in a running relay); nothing else is dialled for it.
	pool.Relays.Range(func(url string, _ *nostr.Relay) bool {
		if url != nostr.NormalizeURL(seed.url) {
			t.Errorf("finding the lists dialled %s", url)
		}
		return true
	})
	if !slices.Contains(relays, nostr.NormalizeURL(accountOnly.url)) || len(relays) != len(before)+1 {
		t.Fatalf("relays = %v, want shared + %s only", relays, accountOnly.url)
	}

	inbox, chat := newTestStore(t), newTestStore(t)
	rejects := &tempRejects{}
	filter := nostr.Filter{Tags: nostr.TagMap{"p": []string{owner, nv}}}
	for range 2 {
		fctx, fcancel := context.WithTimeout(ctx, 5*time.Second)
		fetchAnswered(fctx, relays, filter, func(ev nostr.RelayEvent) {
			processInboxEvent(fctx, ev, inbox, chat, &batchNotifier{}, rejects, false)
		})
		fcancel()
	}
	got, err := inbox.QuerySync(ctx, nostr.Filter{Tags: nostr.TagMap{"p": []string{nv}}})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].ID != note.ID {
		t.Fatalf("inbox for the Nostr Vault account has %d events, want M's note once", len(got))
	}
	if n := pool.Relays.Size(); n > len(relays) {
		t.Fatalf("%d sockets open for %d relays", n, len(relays))
	}
}
