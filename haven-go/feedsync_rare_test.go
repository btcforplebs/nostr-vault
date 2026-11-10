package main

import (
	"context"
	"testing"

	"github.com/nbd-wtf/go-nostr"
	"github.com/spf13/afero"
)

// A relay that did not answer a round used to let the rare kinds' one
// watermark move anyway, so an article only it held from that gap was never
// asked for again. Fake relays only; nothing is opened or published.

func rareRoundFixture(t *testing.T) (state *syncState, floor nostr.Timestamp, follow testKey) {
	t.Helper()
	state = openSyncState(afero.NewMemMapFs(), "db/feed_sync_state.json")
	return state, nostr.Now() - 7*86400, newTestKey(t)
}

func article(t *testing.T, k testKey, at nostr.Timestamp, d string) *nostr.Event {
	t.Helper()
	ev := k.sign(t, nostr.Event{Kind: nostr.KindArticle, CreatedAt: at, Tags: nostr.Tags{{"d", d}}, Content: "article " + d})
	return &ev
}

func TestFeedRareReasksARelayThatWasSilent(t *testing.T) {
	state, floor, follow := rareRoundFixture(t)
	now := nostr.Now()
	onLive := article(t, follow, now-3600, "live")
	onlyOnDown := article(t, follow, now-7200, "down") // published while that relay was down
	relays := map[string]*pagingRelay{"wss://live.example": {held: []*nostr.Event{onLive}}}
	withPagingRelays(t, relays) // wss://down.example is not served: silent
	urls := []string{"wss://live.example", "wss://down.example"}

	got := map[string]bool{}
	publish := func(ev *nostr.Event) { got[ev.ID] = true }

	// Round 1: the down relay does not answer.
	r1 := &feedRareRound{state: state, floor: floor, start: now - 1800}
	pullFeedRare(context.Background(), urls, []string{follow.pk}, r1, publish)
	r1.tidy()
	if !got[onLive.ID] {
		t.Fatal("round 1 missed the live relay's article")
	}
	if at := r1.since(feedRareMarkOwn, "wss://down.example"); at != floor {
		t.Fatalf("the silent relay's mark moved to %d, want the window's edge %d", at, floor)
	}

	// Round 2: it is back, holding an article older than round 1's start.
	relays["wss://down.example"] = &pagingRelay{held: []*nostr.Event{onlyOnDown}}
	r2 := &feedRareRound{state: state, floor: floor, start: now}
	pullFeedRare(context.Background(), urls, []string{follow.pk}, r2, publish)
	if !got[onlyOnDown.ID] {
		t.Fatal("the article missed while its relay was silent was never asked for again")
	}
	// The live relay was asked from its own mark, not the window's edge.
	if at := r2.since(feedRareMarkOwn, "wss://live.example"); at != now-60 {
		t.Fatalf("live relay's next read starts at %d, want %d", at, now-60)
	}
}

// The same on a follow's own relay (the outbox pull).
func TestFeedRareOutboxReasksARelayThatWasSilent(t *testing.T) {
	state, floor, follow := rareRoundFixture(t)
	now := nostr.Now()
	missed := article(t, follow, now-7200, "out")
	relays := map[string]*pagingRelay{}
	withPagingRelays(t, relays)
	plan := map[string][]string{"wss://theirs.example": {follow.pk}}
	got := map[string]bool{}
	publish := func(ev *nostr.Event) { got[ev.ID] = true }

	r1 := &feedRareRound{state: state, floor: floor, start: now - 1800}
	pullFeedOutbox(context.Background(), plan, r1, floor, publish, map[string]int{})

	relays["wss://theirs.example"] = &pagingRelay{held: []*nostr.Event{missed}}
	r2 := &feedRareRound{state: state, floor: floor, start: now}
	pullFeedOutbox(context.Background(), plan, r2, floor, publish, map[string]int{})
	if !got[missed.ID] {
		t.Fatal("the article missed while the follow's relay was silent was never asked for again")
	}
	if at := r2.since(feedRareMarkOutbox, "wss://theirs.example"); at != now-60 {
		t.Fatalf("its mark did not move once it answered: next read at %d, want %d", at, now-60)
	}
}

// Old marks do not pile up: the round-wide mark goes, and so does a relay's
// mark once it is at or below the window's edge.
func TestFeedRareTidyDropsStaleMarks(t *testing.T) {
	state, floor, _ := rareRoundFixture(t)
	state.setMark(feedRareMarkOld, int64(floor+10))
	state.setMark(feedRareMarkOwn+"wss://gone.example", int64(floor-1))
	state.setMark(feedRareMarkOutbox+"wss://kept.example", int64(floor+5))
	state.setMark("feed", int64(floor-100)) // not a rare mark: left alone
	(&feedRareRound{state: state, floor: floor}).tidy()
	if _, ok := state.data.Marks[feedRareMarkOld]; ok {
		t.Error("the old round-wide mark was kept")
	}
	if _, ok := state.data.Marks[feedRareMarkOwn+"wss://gone.example"]; ok {
		t.Error("a mark at the window's edge was kept")
	}
	if _, ok := state.data.Marks[feedRareMarkOutbox+"wss://kept.example"]; !ok {
		t.Error("a live mark was dropped")
	}
	if _, ok := state.data.Marks["feed"]; !ok {
		t.Error("the common mark was dropped")
	}
}
