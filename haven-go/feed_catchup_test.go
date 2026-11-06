package main

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

func dvmPK(c byte) string { return strings.Repeat(string(c), 64) }

func dvmNote(id, author string, at time.Time, tags ...nostr.Tag) *nostr.Event {
	return &nostr.Event{ID: id, PubKey: author, Kind: 1, CreatedAt: nostr.Timestamp(at.Unix()), Tags: nostr.Tags(tags)}
}

func TestCatchUpKeepsOneNewestPostPerPersonNewestFirst(t *testing.T) {
	now := time.Now()
	a, b, c := dvmPK('a'), dvmPK('b'), dvmPK('c')
	wanted := map[string]struct{}{a: {}, b: {}}
	events := []*nostr.Event{
		dvmNote("a-old", a, now.Add(-5*time.Hour)),
		dvmNote("a-new", a, now.Add(-1*time.Hour)),
		// A reply is not their post: skipped even though it is newer.
		dvmNote("a-reply", a, now.Add(-10*time.Minute), nostr.Tag{"e", "x", "", "reply"}),
		dvmNote("b-only", b, now.Add(-30*time.Minute)),
		// Not followed.
		dvmNote("c-new", c, now),
	}
	got := pickLatestPerAuthor(events, wanted, now)
	if len(got) != 2 || got[0].ID != "b-only" || got[1].ID != "a-new" {
		t.Fatalf("got %+v, want [b-only a-new]", dvmIDs(got))
	}
}

func TestCatchUpKeepsAQuoteButNotStaleOrFutureNotes(t *testing.T) {
	now := time.Now()
	a, b, c := dvmPK('a'), dvmPK('b'), dvmPK('c')
	wanted := map[string]struct{}{a: {}, b: {}, c: {}}
	events := []*nostr.Event{
		// A NIP-10 "mention" e tag is a quote, not a parent.
		dvmNote("a-quote", a, now.Add(-time.Hour), nostr.Tag{"e", "x", "", "mention"}),
		dvmNote("b-stale", b, now.Add(-catchUpWindow-time.Hour)),
		dvmNote("c-future", c, now.Add(time.Hour)),
	}
	got := pickLatestPerAuthor(events, wanted, now)
	if len(got) != 1 || got[0].ID != "a-quote" {
		t.Fatalf("got %v, want [a-quote]", dvmIDs(got))
	}
}

func TestNormalizeFollowsDropsJunkAndDuplicates(t *testing.T) {
	a := dvmPK('a')
	got := normalizeFollows([]string{strings.ToUpper(a), a, "npub1xyz", "", " " + dvmPK('b') + " "})
	if len(got) != 2 || got[0] != a || got[1] != dvmPK('b') {
		t.Fatalf("got %v", got)
	}
}

// Only the people nothing local had are asked of the network.
func TestCatchUpAsksTheNetworkOnlyForMissingPeople(t *testing.T) {
	saved := fetchCatchUpFromNetwork
	defer func() { fetchCatchUpFromNetwork = saved }()
	var asked []string
	fetchCatchUpFromNetwork = func(_ context.Context, authors []string, _ nostr.Timestamp) []*nostr.Event {
		asked = authors
		return []*nostr.Event{dvmNote("from-net", dvmPK('a'), time.Now().Add(-time.Minute))}
	}
	got, err := computeCatchUpNotes(context.Background(), []string{dvmPK('a')})
	if err != nil || len(got) != 1 || got[0].ID != "from-net" {
		t.Fatalf("got %v, %v", dvmIDs(got), err)
	}
	if len(asked) != 1 || asked[0] != dvmPK('a') {
		t.Fatalf("asked %v", asked)
	}
	// Nobody to ask for: no network.
	asked = nil
	if _, err := computeCatchUpNotes(context.Background(), []string{"junk"}); err != nil || asked != nil {
		t.Fatalf("asked %v for no follows", asked)
	}
}

func dvmIDs(notes []PopularNote) []string {
	out := make([]string, len(notes))
	for i, n := range notes {
		out[i] = n.ID
	}
	return out
}

// A relay's note is kept only if its id is its hash and its signature holds:
// a note signed under someone else's id is dropped (Tron, #1830).
func TestVerifiedRelayEventRejectsAForgedID(t *testing.T) {
	sk := nostr.GeneratePrivateKey()
	ev := &nostr.Event{Kind: 1, Content: "hi", CreatedAt: nostr.Now(), Tags: nostr.Tags{}}
	if err := ev.Sign(sk); err != nil {
		t.Fatal(err)
	}
	if !verifiedRelayEvent(ev) {
		t.Fatal("a real signed event must pass")
	}
	forged := *ev
	forged.ID = dvmPK('f')
	if err := forged.Sign(sk); err != nil {
		t.Fatal(err)
	}
	forged.ID = dvmPK('f')
	if verifiedRelayEvent(&forged) || verifiedRelayEvent(nil) {
		t.Fatal("an id that is not the event's hash must fail")
	}
}
