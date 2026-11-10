package main

import (
	"context"
	"testing"

	"github.com/nbd-wtf/go-nostr"
)

// Health audit B1 (2026-11-08): with the follows' own relays in the round
// (#1843) the feed watermark stopped moving. Each per-relay outbox pull
// dropped the owner relays' streaks, so the #1721 escape never fired, and a
// follow's relay that never answers kept every round incomplete. Either way
// each hourly round re-read the whole window from every relay.

func feedRoundFixture(t *testing.T) (ownFilter nostr.Filter, owner, follow testKey) {
	t.Helper()
	owner, follow = newTestKey(t), newTestKey(t)
	since := nostr.Timestamp(0)
	return nostr.Filter{Authors: []string{owner.pk}, Kinds: []int{nostr.KindTextNote}, Since: &since}, owner, follow
}

func planOf(p map[string][]string) func() map[string][]string {
	return func() map[string][]string { return p }
}

// An owner relay that keeps stopping partway holds the watermark for
// feedShortHoldRounds rounds, then lets go, also when the round asks
// follows' relays too.
func TestFeedRoundEscapeStillWorksWithFollowRelays(t *testing.T) {
	ownFilter, owner, follow := feedRoundFixture(t)
	withPagingRelays(t, map[string]*pagingRelay{
		"wss://tired.example": {held: notesOf(t, owner, 1200, 100_000), cap: 300, quiet: 1},
		"wss://their.example": {held: notesOf(t, follow, 50, 100_000)},
	})
	plan := planOf(map[string][]string{"wss://their.example": {follow.pk}})
	streaks := newFeedRoundStreaks()
	got := 0
	// Spelled out, not read from the constant: holding forever must fail here.
	for round, want := range []bool{false, false, true, true, true} {
		complete := feedCatchupPulls(context.Background(), []string{"wss://tired.example"}, ownFilter, plan, nil, 0,
			func(ev *nostr.Event) {
				if ev.PubKey == follow.pk {
					got++
				}
			}, streaks)
		if complete != want {
			t.Fatalf("round %d: complete=%v, want %v (owner streaks %v)", round+1, complete, want, streaks.owner)
		}
	}
	if got == 0 {
		t.Fatal("the follow's relay was not read")
	}
}

// A follow's relay that never answers is skipped: the round still counts as
// read, and the follow's live relay is still read.
func TestFeedRoundSkipsADeadFollowRelay(t *testing.T) {
	ownFilter, owner, follow := feedRoundFixture(t)
	other := newTestKey(t)
	withPagingRelays(t, map[string]*pagingRelay{
		"wss://own.example":   {held: notesOf(t, owner, 100, 100_000)},
		"wss://their.example": {held: notesOf(t, other, 20, 100_000)},
		// wss://dead.example is not served: no EOSE, nothing (silent).
	})
	plan := map[string][]string{"wss://dead.example": {follow.pk}, "wss://their.example": {other.pk}}
	streaks := newFeedRoundStreaks()
	for round := 1; round <= 3; round++ {
		got := 0
		complete := feedCatchupPulls(context.Background(), []string{"wss://own.example"}, ownFilter, planOf(plan), nil, 0,
			func(ev *nostr.Event) {
				if ev.PubKey == other.pk {
					got++
				}
			}, streaks)
		if !complete {
			t.Fatalf("round %d: a dead follow relay kept the round incomplete", round)
		}
		if got != 20 {
			t.Fatalf("round %d: got %d of the live follow relay's 20 notes", round, got)
		}
	}
	// The outbox pull on its own says the same.
	if !pullFeedOutbox(context.Background(), map[string][]string{"wss://dead.example": {follow.pk}}, nil, 0,
		func(*nostr.Event) {}, map[string]int{}) {
		t.Fatal("pullFeedOutbox counted a silent relay as an unread round")
	}
}

// A follow's relay that stops partway holds the watermark like an owner
// relay, and gets the same escape.
func TestFeedRoundFollowRelayStoppingPartwayGetsTheEscape(t *testing.T) {
	ownFilter, owner, follow := feedRoundFixture(t)
	withPagingRelays(t, map[string]*pagingRelay{
		"wss://own.example":   {held: notesOf(t, owner, 100, 100_000)},
		"wss://tired.example": {held: notesOf(t, follow, 1200, 100_000), cap: 300, quiet: 1},
	})
	plan := planOf(map[string][]string{"wss://tired.example": {follow.pk}})
	streaks := newFeedRoundStreaks()
	for round, want := range []bool{false, false, true, true} {
		complete := feedCatchupPulls(context.Background(), []string{"wss://own.example"}, ownFilter, plan, nil, 0,
			func(*nostr.Event) {}, streaks)
		if complete != want {
			t.Fatalf("round %d: complete=%v, want %v (outbox streaks %v)", round+1, complete, want, streaks.outbox)
		}
	}
	if len(streaks.owner) != 0 {
		t.Fatalf("a follow relay's streak landed in the owner's map: %v", streaks.owner)
	}
}
