package main

import (
	"context"
	"strings"
	"testing"

	"github.com/fiatjaf/eventstore"
	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/internal/negsync"
)

// negOpenCtx is the context khatru hands the QueryEvents hooks for a served
// NEG-OPEN: a negentropy session carrying the vector mark (negsync.go init).
func negOpenCtx(ctx context.Context) context.Context {
	return negsync.ForVector(eventstore.SetNegentropy(ctx))
}

// A NEG-OPEN on /lists gets every version: queryListHistory keeps rows by
// kind and author, which the vector stubs lack (Tron, PR 1956: 0 ids marked).
func TestListsNegOpenGetsEveryVersion(t *testing.T) {
	forEachHistoryBackend(t, func(t *testing.T, f *listHistoryFixture) {
		v1, v2, v3 := f.bookmarks(3, 1), f.bookmarks(4, 2), f.bookmarks(5, 3)
		f.publish(v1, v2, v3)
		ch, err := queryListHistory(negOpenCtx(f.ctx), f.history, nostr.Filter{Kinds: []int{10003}, Authors: []string{f.pk}})
		if err != nil {
			t.Fatal(err)
		}
		var ids []string
		for ev := range ch {
			ids = append(ids, ev.ID)
		}
		if want := []string{v3.ID, v2.ID, v1.ID}; strings.Join(ids, ",") != strings.Join(want, ",") {
			t.Fatalf("NEG-OPEN versions = %v, want %v", ids, want)
		}
	})
}

// A stranger's NEG-OPEN on the outbox and the inbox must not list a
// brought-over account's events: the hide wrappers read author and p tags,
// which the vector stubs lack.
func TestNegOpenHidesBroughtAccounts(t *testing.T) {
	me, stranger, alice := newTestKey(t), newTestKey(t), newTestKey(t)
	openCopyVault(t, me.pk)
	t.Cleanup(resetLiveAccounts)
	now := nostr.Now()
	strangerNote := stranger.sign(t, nostr.Event{Kind: 1, CreatedAt: now, Content: "theirs"})
	myNote := me.sign(t, nostr.Event{Kind: 1, CreatedAt: now, Content: "mine"})
	toStranger := alice.sign(t, nostr.Event{Kind: 1, CreatedAt: now, Content: "hi stranger", Tags: nostr.Tags{{"p", stranger.pk}}})
	toMe := alice.sign(t, nostr.Event{Kind: 1, CreatedAt: now, Content: "hi me", Tags: nostr.Tags{{"p", me.pk}}})
	accounts := `{"v":1,"updated_at":1,"accounts":[{"npub":"` + npubOf(t, stranger.pk) + `"},{"npub":"` + npubOf(t, me.pk) + `"}]}`
	zipPath := writeStoresZip(t, accounts, map[string][]nostr.Event{
		"outbox": {strangerNote, myNote},
		"inbox":  {toStranger, toMe},
	})
	if err := importFromZip(context.Background(), zipPath); err != nil {
		t.Fatalf("stranger zip naming the owner: %v", err)
	}
	ids := func(ch chan *nostr.Event, err error) map[string]bool {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
		got := map[string]bool{}
		for ev := range ch {
			got[ev.ID] = true
		}
		return got
	}
	neg := negOpenCtx(context.Background())
	kind1 := nostr.Filter{Kinds: []int{1}}

	// Control: unwrapped, a marked read is stubs (no author), so the hiding
	// below is what is under test, not a store that ignores the mark.
	ch, err := outboxDB.QueryEvents(neg, kind1)
	if err != nil {
		t.Fatal(err)
	}
	stubs := 0
	for ev := range ch {
		if ev.PubKey == "" {
			stubs++
		}
	}
	if stubs == 0 {
		t.Fatal("control: the outbox store answered a marked read with whole events; this test proves nothing")
	}

	outbox := hideBroughtQuery(outboxDB.QueryEvents)
	if got := ids(outbox(neg, kind1)); got[strangerNote.ID] || !got[myNote.ID] {
		t.Fatalf("outbox NEG-OPEN = %v: want my note, not the stranger's", got)
	}
	inbox := hideBroughtInboxQuery(inboxDB.QueryEvents)
	if got := ids(inbox(neg, kind1)); got[toStranger.ID] || !got[toMe.ID] {
		t.Fatalf("inbox NEG-OPEN = %v: want mail to me, not the stranger's", got)
	}
	// The vault's own reader still reconciles them all.
	if got := ids(outbox(negOpenCtx(authedAs(me.pk)), kind1)); !got[strangerNote.ID] || !got[myNote.ID] {
		t.Fatalf("owner NEG-OPEN on the outbox = %v, want both", got)
	}
}
