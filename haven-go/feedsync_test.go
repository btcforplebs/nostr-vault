package main

import (
	"context"
	"slices"
	"testing"

	"github.com/nbd-wtf/go-nostr"
)

// The rare kinds must never share a REQ with the common ones: relays cap a
// REQ, and notes fill the cap first.
func TestFeedCatchupFiltersSplitRareKinds(t *testing.T) {
	authors := []string{hexid('1')}
	common, rare := feedCommonFilter(authors, 100), feedRareFilter(authors, 50)

	for _, k := range rareFeedKinds {
		if slices.Contains(common.Kinds, k) {
			t.Fatalf("rare kind %d is in the common REQ", k)
		}
		if !slices.Contains(rare.Kinds, k) {
			t.Fatalf("rare kind %d is missing from the rare REQ", k)
		}
	}
	for _, k := range []int{nostr.KindArticle, KindPoll, nostr.KindGenericRepost, KindPicture, nostr.KindHighlights} {
		if !slices.Contains(rare.Kinds, k) {
			t.Fatalf("kind %d is not fetched in the rare REQ", k)
		}
	}
	got := slices.Sorted(slices.Values(slices.Concat(common.Kinds, rare.Kinds)))
	want := slices.Sorted(slices.Values(feedKinds))
	if !slices.Equal(got, want) {
		t.Fatalf("catch-up kinds %v, want every feed kind %v", got, want)
	}
	if *common.Since != 100 || *rare.Since != 50 {
		t.Fatalf("since common=%d rare=%d, want each its own watermark", *common.Since, *rare.Since)
	}
	if !slices.Equal(common.Authors, authors) || !slices.Equal(rare.Authors, authors) {
		t.Fatal("both REQs must ask for the follow set")
	}
}

func TestFeedStoreAcceptsRareKinds(t *testing.T) {
	owner := hexid('0')
	follow := hexid('1')
	setupSyncConfig(owner)

	ctx := context.Background()
	feed := newTestStore(t)
	s := &feedNegStore{feed: feed, follows: map[string]struct{}{follow: {}}}

	now := nostr.Now()
	for i, kind := range rareFeedKinds {
		ev := nostr.Event{ID: hexid(byte('a' + i)), PubKey: follow, Kind: kind, CreatedAt: now,
			Tags: nostr.Tags{{"d", "x"}}}
		if err := s.Publish(ctx, ev); err != nil {
			t.Fatal(err)
		}
		if got, _ := feed.QuerySync(ctx, nostr.Filter{IDs: []string{ev.ID}}); len(got) != 1 {
			t.Fatalf("kind %d from a follow was not cached", kind)
		}
		if reject, _ := OnlyFeedKinds(ctx, &ev); reject {
			t.Fatalf("/feed route rejects kind %d", kind)
		}
	}
}

// The feed's catch-up used to be one request per round, so a relay's answer
// cap was taken as the whole round and the watermark moved past what it cut
// (Tidy import audit, item 8). It is paged now, and says when it read all.
func TestFeedFallbackPullPagesPastTheCapAndSaysWhenComplete(t *testing.T) {
	owner := newTestKey(t)
	held := notesOf(t, owner, 1200, 100_000)
	since := nostr.Timestamp(0)
	filter := nostr.Filter{Authors: []string{owner.pk}, Kinds: []int{nostr.KindTextNote}, Since: &since}

	withPagingRelays(t, map[string]*pagingRelay{"wss://capped.example": {held: held, cap: 300}})
	got := 0
	if !feedFallbackPull(context.Background(), []string{"wss://capped.example"}, filter, func(*nostr.Event) { got++ }) {
		t.Fatal("a round that read everything was not complete")
	}
	if got != 1200 {
		t.Fatalf("published %d of 1200: the cap of 300 cut the round", got)
	}

	// Stops partway (answers, then goes quiet): the round is not complete,
	// so the watermark stays for the next round to ask again.
	withPagingRelays(t, map[string]*pagingRelay{"wss://tired.example": {held: held, cap: 300, quiet: 1}})
	if feedFallbackPull(context.Background(), []string{"wss://tired.example"}, filter, func(*nostr.Event) {}) {
		t.Fatal("a round cut partway was called complete")
	}
}
