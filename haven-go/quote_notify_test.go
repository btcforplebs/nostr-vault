package main

import (
	"bytes"
	"context"
	"log"
	"strings"
	"testing"

	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/pkg/wot"
)

// realPubkey returns a valid public key: an address (kind:pubkey:d) only
// parses when its pubkey is a point on the curve, which hexid's are not.
func realPubkey(t *testing.T) string {
	t.Helper()
	pk, err := nostr.GetPublicKey(nostr.GeneratePrivateKey())
	if err != nil {
		t.Fatal(err)
	}
	return pk
}

// quoteFixture stores an owner note, an owner article and someone else's
// note in a fresh outbox, with a WoT that admits nobody.
func quoteFixture(t *testing.T) (owner, other string, ownerNote, ownerArticle, otherNote *nostr.Event) {
	t.Helper()
	owner = realPubkey(t)
	other = realPubkey(t)
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

	ownerNote = &nostr.Event{ID: hexid('a'), PubKey: owner, Kind: nostr.KindTextNote, CreatedAt: nostr.Now(), Tags: nostr.Tags{}}
	ownerArticle = &nostr.Event{ID: hexid('b'), PubKey: owner, Kind: nostr.KindArticle, CreatedAt: nostr.Now(), Tags: nostr.Tags{{"d", "my-article"}}}
	otherNote = &nostr.Event{ID: hexid('c'), PubKey: other, Kind: nostr.KindTextNote, CreatedAt: nostr.Now(), Tags: nostr.Tags{}}
	for _, ev := range []*nostr.Event{ownerNote, ownerArticle, otherNote} {
		if err := db.SaveEvent(context.Background(), ev); err != nil {
			t.Fatal(err)
		}
	}
	return
}

// A stranger quoting the owner, or commenting on the owner's article, is
// accepted like a reply; quoting someone else, or naming an article the
// owner never wrote, is not.
func TestClassifyAcceptsQuotesAndArticleCommentsFromOutsideWot(t *testing.T) {
	owner, other, ownerNote, _, otherNote := quoteFixture(t)
	stranger := hexid('1')
	articleAddr := "30023:" + owner + ":my-article"

	ev := func(id byte, kind int, tags nostr.Tags) *nostr.Event {
		return &nostr.Event{ID: hexid(id), PubKey: stranger, Kind: kind, CreatedAt: nostr.Now(), Tags: tags}
	}
	cases := []struct {
		name   string
		ev     *nostr.Event
		accept bool
	}{
		{"q quote of owner note", ev('d', nostr.KindTextNote, nostr.Tags{{"q", ownerNote.ID, "", owner}, {"p", owner}}), true},
		{"legacy e-mention quote of owner note", ev('e', nostr.KindTextNote, nostr.Tags{{"e", ownerNote.ID, "", "mention"}, {"p", owner}}), true},
		{"q quote of owner article by address", ev('f', nostr.KindTextNote, nostr.Tags{{"q", articleAddr}, {"p", owner}}), true},
		{"NIP-22 comment on owner article", ev('0', nostr.KindComment, nostr.Tags{{"A", articleAddr}, {"a", articleAddr}, {"K", "30023"}, {"p", owner}}), true},
		{"kind 1 reply to owner article", ev('2', nostr.KindTextNote, nostr.Tags{{"a", articleAddr, "", "root"}, {"p", owner}}), true},
		{"quote of someone else's note", ev('3', nostr.KindTextNote, nostr.Tags{{"q", otherNote.ID, "", other}, {"p", owner}}), false},
		{"quote whose hint lies about the author", ev('4', nostr.KindTextNote, nostr.Tags{{"q", otherNote.ID, "", owner}, {"p", owner}}), false},
		{"address of an article the owner never wrote", ev('5', nostr.KindComment, nostr.Tags{{"A", "30023:" + owner + ":made-up"}, {"p", owner}}), false},
		{"address naming the owner on someone else's article", ev('6', nostr.KindComment, nostr.Tags{{"A", "30023:" + other + ":my-article"}, {"p", owner}}), false},
		{"reaction to owner article", ev('7', nostr.KindReaction, nostr.Tags{{"a", articleAddr}, {"p", owner}}), false},
	}
	for _, c := range cases {
		got := classifyInboxEvent(context.Background(), c.ev)
		if got.accept != c.accept {
			t.Errorf("%s: accept = %v, want %v (reason %v)", c.name, got.accept, c.accept, got.reason)
		}
	}
}

// notifyType runs emitInboxNotify and returns the type it announced, or ""
// when it printed nothing.
func notifyType(t *testing.T, ev *nostr.Event, recipient string) string {
	t.Helper()
	var buf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(prev)
	emitInboxNotify(ev, recipient)
	line := buf.String()
	i := strings.Index(line, "|type=")
	if i < 0 {
		return ""
	}
	rest := line[i+len("|type="):]
	return rest[:strings.Index(rest, "|")]
}

func TestEmitInboxNotifyNamesQuotes(t *testing.T) {
	owner, other, ownerNote, _, otherNote := quoteFixture(t)
	articleAddr := "30023:" + owner + ":my-article"
	friend := hexid('1')
	ev := func(kind int, tags nostr.Tags) *nostr.Event {
		return &nostr.Event{ID: hexid('9'), PubKey: friend, Kind: kind, CreatedAt: nostr.Now(), Tags: tags}
	}
	cases := []struct {
		name string
		ev   *nostr.Event
		want string
	}{
		{"q quote of owner note", ev(nostr.KindTextNote, nostr.Tags{{"q", ownerNote.ID}, {"p", owner}}), "quote"},
		{"q quote of owner article", ev(nostr.KindTextNote, nostr.Tags{{"q", articleAddr}, {"p", owner}}), "quote"},
		// Older clients mark a quote as an e tag with the "mention" marker;
		// it used to be announced as a reply.
		{"legacy e-mention quote", ev(nostr.KindTextNote, nostr.Tags{{"e", ownerNote.ID, "", "mention"}, {"p", owner}}), "quote"},
		{"quote of someone else's note that tags the owner", ev(nostr.KindTextNote, nostr.Tags{{"q", otherNote.ID, "", other}, {"p", owner}}), "mention"},
		{"legacy e-mention of someone else's note", ev(nostr.KindTextNote, nostr.Tags{{"e", otherNote.ID, "", "mention"}, {"p", owner}}), "mention"},
		{"reply that also quotes", ev(nostr.KindTextNote, nostr.Tags{{"e", ownerNote.ID, "", "root"}, {"q", ownerNote.ID}, {"p", owner}}), "reply"},
		{"plain reply", ev(nostr.KindTextNote, nostr.Tags{{"e", ownerNote.ID}, {"p", owner}}), "reply"},
		{"bare mention", ev(nostr.KindTextNote, nostr.Tags{{"p", owner}}), "mention"},
		{"kind 6 repost", ev(nostr.KindRepost, nostr.Tags{{"e", ownerNote.ID}, {"p", owner}}), "repost"},
		{"kind 16 generic repost", ev(nostr.KindGenericRepost, nostr.Tags{{"a", articleAddr}, {"k", "30023"}, {"p", owner}}), "repost"},
	}
	for _, c := range cases {
		if got := notifyType(t, c.ev, owner); got != c.want {
			t.Errorf("%s: type = %q, want %q", c.name, got, c.want)
		}
	}
}
