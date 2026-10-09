package main

import (
	"context"
	"testing"

	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/pkg/wot"
)

// A reply to one of the owner's own posts is accepted from anyone outside
// the WoT; a bare mention, or a reply to someone else's post, is not.
func TestClassifyAcceptsRepliesToOwnerPostsFromOutsideWot(t *testing.T) {
	owner := hexid('0')
	stranger := hexid('1')
	other := hexid('2')
	setupSyncConfig(owner)
	wot.MarkReady(wot.NewCycle(), stubWot{allow: false})

	saved := outboxDB
	t.Cleanup(func() { outboxDB = saved })
	db := newBadgerBackend(t.TempDir() + "/outbox")
	if err := db.Init(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	outboxDB = db

	ctx := context.Background()
	ownerPost := &nostr.Event{ID: hexid('a'), PubKey: owner, Kind: nostr.KindTextNote, CreatedAt: nostr.Now(), Tags: nostr.Tags{}}
	otherPost := &nostr.Event{ID: hexid('b'), PubKey: other, Kind: nostr.KindTextNote, CreatedAt: nostr.Now(), Tags: nostr.Tags{}}
	for _, ev := range []*nostr.Event{ownerPost, otherPost} {
		if err := db.SaveEvent(ctx, ev); err != nil {
			t.Fatal(err)
		}
	}

	ev := func(id byte, kind int, tags nostr.Tags) *nostr.Event {
		return &nostr.Event{ID: hexid(id), PubKey: stranger, Kind: kind, CreatedAt: nostr.Now(), Tags: tags}
	}
	cases := []struct {
		name   string
		ev     *nostr.Event
		accept bool
	}{
		{"reply to owner post", ev('c', nostr.KindTextNote, nostr.Tags{{"e", ownerPost.ID, "", "root"}, {"p", owner}}), true},
		{"unmarked e tag to owner post", ev('d', nostr.KindTextNote, nostr.Tags{{"e", ownerPost.ID}, {"p", owner}}), true},
		{"NIP-22 comment on owner post", ev('e', nostr.KindComment, nostr.Tags{{"E", ownerPost.ID}, {"p", owner}}), true},
		{"bare mention", ev('f', nostr.KindTextNote, nostr.Tags{{"p", owner}}), false},
		{"reply to someone else's post", ev('g', nostr.KindTextNote, nostr.Tags{{"e", otherPost.ID}, {"p", owner}}), false},
		{"reply to an unknown post", ev('h', nostr.KindTextNote, nostr.Tags{{"e", hexid('9')}, {"p", owner}}), false},
		{"reaction to owner post", ev('i', nostr.KindReaction, nostr.Tags{{"e", ownerPost.ID}, {"p", owner}}), false},
	}
	for _, c := range cases {
		got := classifyInboxEvent(ctx, c.ev)
		if got.accept != c.accept {
			t.Errorf("%s: accept = %v, want %v (reason %v)", c.name, got.accept, c.accept, got.reason)
		}
		if c.accept && !got.notify {
			t.Errorf("%s: accepted but not notified", c.name)
		}
	}

	// Blacklisted authors stay out even when replying to the owner.
	config.BlacklistedPubKeys[stranger] = struct{}{}
	if got := classifyInboxEvent(ctx, cases[0].ev); got.accept {
		t.Error("blacklisted author's reply was accepted")
	}
}
