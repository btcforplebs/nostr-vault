package main

import (
	"testing"

	"github.com/nbd-wtf/go-nostr"
)

// NIP-25: the note being reacted to is the LAST e-tag, not the first. Taking
// the first credits the thread root for a reaction to a reply.
func TestReactionTargetIDUsesLastETag(t *testing.T) {
	cases := []struct {
		name string
		tags nostr.Tags
		want string
	}{
		{"no tags", nostr.Tags{}, ""},
		{"no e-tag", nostr.Tags{{"p", "author"}}, ""},
		{"single e-tag", nostr.Tags{{"e", "note1"}}, "note1"},
		{
			"reply thread: root first, reacted note last",
			nostr.Tags{{"e", "root"}, {"p", "author"}, {"e", "reply"}},
			"reply",
		},
		{"malformed e-tag is skipped", nostr.Tags{{"e"}, {"e", "note1"}}, "note1"},
	}
	for _, c := range cases {
		if got := reactionTargetID(c.tags); got != c.want {
			t.Errorf("%s: reactionTargetID = %q, want %q", c.name, got, c.want)
		}
	}
}

// The whole point of the rewrite: five hundred likes from one account are one
// reactor, not five hundred points.
func TestAddEngagementCountsAReactorOnce(t *testing.T) {
	tally := map[string]map[string]float64{}
	for i := 0; i < 500; i++ {
		addEngagement(tally, &nostr.Event{
			Kind:   7,
			PubKey: "spammer",
			Tags:   nostr.Tags{{"e", "note1"}},
		})
	}
	if got := len(tally["note1"]); got != 1 {
		t.Fatalf("500 likes from one account produced %d reactors, want 1", got)
	}
	if got := tally["note1"]["spammer"]; got != 1.0 {
		t.Errorf("weight = %v, want 1.0", got)
	}
}

// A reactor keeps their strongest action, regardless of arrival order.
func TestAddEngagementKeepsStrongestWeightPerReactor(t *testing.T) {
	for _, order := range [][]int{{7, 6, 9735}, {9735, 6, 7}} {
		tally := map[string]map[string]float64{}
		for _, kind := range order {
			addEngagement(tally, &nostr.Event{
				Kind:   kind,
				PubKey: "alice",
				Tags:   nostr.Tags{{"e", "note1"}},
			})
		}
		if got := tally["note1"]["alice"]; got != 3.0 {
			t.Errorf("order %v: weight = %v, want 3.0 (the zap)", order, got)
		}
		if got := len(tally["note1"]); got != 1 {
			t.Errorf("order %v: reactors = %d, want 1", order, got)
		}
	}
}

// An unexpected kind must not create a zero-weight entry — that would add
// nothing to the score while still counting towards the distinct floor.
func TestAddEngagementIgnoresUnscoredKinds(t *testing.T) {
	tally := map[string]map[string]float64{}
	addEngagement(tally, &nostr.Event{
		Kind:   1,
		PubKey: "alice",
		Tags:   nostr.Tags{{"e", "note1"}},
	})
	if len(tally) != 0 {
		t.Errorf("kind 1 created a tally entry: %v", tally)
	}
}

func TestRankTargetsAppliesDistinctReactorFloor(t *testing.T) {
	tally := map[string]map[string]float64{
		"selfboost": {"spammer": 1},
		"small":     {"a": 1, "b": 1},
		"real":      {"a": 1, "b": 1, "c": 2, "d": 3, "e": 1},
	}
	ranked := rankTargets(tally, 5)
	if len(ranked) != 1 || ranked[0].id != "real" {
		t.Fatalf("ranked = %v, want only the note with 5 distinct reactors", ranked)
	}
	if ranked[0].score != 8 {
		t.Errorf("score = %v, want 8 (1+1+2+3+1)", ranked[0].score)
	}
}

// Go randomises map iteration, so equal scores must break on a stable key or
// two runs over identical data disagree about the ordering.
func TestRankTargetsOrderIsTotal(t *testing.T) {
	tally := map[string]map[string]float64{}
	for _, id := range []string{"aaa", "bbb", "ccc", "ddd", "eee"} {
		tally[id] = map[string]float64{"a": 1, "b": 1, "c": 1}
	}
	first := rankTargets(tally, 3)
	for i := 0; i < 20; i++ {
		got := rankTargets(tally, 3)
		for j := range got {
			if got[j].id != first[j].id {
				t.Fatalf("run %d disagreed at %d: %q vs %q", i, j, got[j].id, first[j].id)
			}
		}
	}
}

func TestScoreExcludingAuthor(t *testing.T) {
	reactors := map[string]float64{"author": 3, "a": 1, "b": 2}
	score, distinct := scoreExcludingAuthor(reactors, "author")
	if score != 3 {
		t.Errorf("score = %v, want 3 (author's own zap excluded)", score)
	}
	if distinct != 2 {
		t.Errorf("distinct = %d, want 2", distinct)
	}
}

// An author plus two friends is not three independent people.
func TestScoreExcludingAuthorCanDropBelowFloor(t *testing.T) {
	reactors := map[string]float64{"author": 1, "a": 1, "b": 1}
	if len(reactors) < minTrustedReactors {
		t.Fatalf("test setup: want a note that passes the raw floor")
	}
	_, distinct := scoreExcludingAuthor(reactors, "author")
	if distinct >= minTrustedReactors {
		t.Errorf("distinct = %d, want below the floor of %d", distinct, minTrustedReactors)
	}
}

func TestCapPerAuthorKeepsBestAndPreservesOrder(t *testing.T) {
	// Input is already sorted by score, as the caller guarantees.
	in := []PopularNote{
		{ID: "a1", PubKey: "a", Score: 10},
		{ID: "a2", PubKey: "a", Score: 9},
		{ID: "b1", PubKey: "b", Score: 8},
		{ID: "a3", PubKey: "a", Score: 7},
		{ID: "a4", PubKey: "a", Score: 6},
		{ID: "b2", PubKey: "b", Score: 5},
	}
	got := capPerAuthor(in, 3)
	want := []string{"a1", "a2", "b1", "a3", "b2"}
	if len(got) != len(want) {
		t.Fatalf("kept %d notes, want %d: %v", len(got), len(want), got)
	}
	for i, id := range want {
		if got[i].ID != id {
			t.Errorf("position %d = %q, want %q", i, got[i].ID, id)
		}
	}
}

// A spam farm that clears the reactor floor still cannot own the screen.
func TestCapPerAuthorLimitsOneAuthorFillingTheFeed(t *testing.T) {
	var in []PopularNote
	for i := 0; i < 100; i++ {
		in = append(in, PopularNote{ID: string(rune('a' + i%26)), PubKey: "farm", Score: float64(100 - i)})
	}
	if got := len(capPerAuthor(in, maxNotesPerAuthor)); got != maxNotesPerAuthor {
		t.Errorf("kept %d of one author's notes, want %d", got, maxNotesPerAuthor)
	}
}

func TestCapPerAuthorZeroLimitIsANoop(t *testing.T) {
	in := []PopularNote{{ID: "a1", PubKey: "a"}, {ID: "a2", PubKey: "a"}}
	if got := len(capPerAuthor(in, 0)); got != 2 {
		t.Errorf("limit 0 kept %d, want all %d", got, len(in))
	}
}
