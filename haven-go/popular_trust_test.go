package main

// Tests for the web-of-trust gate on the Popular feed.
//
// Note on shared state: wot's instance is a process-wide atomic.Value, and
// other test files in this package install their own graph into it. Every test
// here therefore installs the graph it needs rather than assuming one — the
// first version of these tests passed only because negsync_test.go happened to
// have left an allow-everyone stub behind, and failed the moment they were run
// with -run.

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/barrydeen/haven/pkg/wot"
)

// installGraph makes the given pubkeys the owner's web of trust for this test.
func installGraph(t *testing.T, members ...string) {
	t.Helper()
	set := make(map[string]bool, len(members))
	for _, pk := range members {
		set[pk] = true
	}
	wot.MarkReady(wot.NewCycle(), stubWot{members: set})
}

// installOpenGraph installs the WOT_DEPTH=0 shape: a model that vouches for
// everyone. The gate must then be a no-op, not a wall.
func installOpenGraph(t *testing.T) {
	t.Helper()
	wot.MarkReady(wot.NewCycle(), stubWot{allow: true})
}

// installEmptyGraph installs the cold-start shape: a real graph with nothing
// in it yet, which answers false for every pubkey.
func installEmptyGraph(t *testing.T) {
	t.Helper()
	wot.MarkReady(wot.NewCycle(), stubWot{members: map[string]bool{}})
}

// The shape of the real campaign, in miniature: a note boosted by a hundred
// accounts nobody knows, against one carried by three the owner's network
// vouches for. The manufactured audience is the larger number and must lose.
func TestTrustGateDropsManufacturedEngagement(t *testing.T) {
	ctx := context.Background()
	trusted := []string{"friend1", "friend2", "friend3"}
	installGraph(t, trusted...)

	tally := map[string]map[string]float64{}
	for i := 0; i < 100; i++ {
		addEngagement(tally, engagement(7, fmt.Sprintf("bot%d", i), "campaign", time.Now()))
	}
	for _, pk := range trusted {
		addEngagement(tally, engagement(7, pk, "genuine", time.Now()))
	}

	// Ungated, the campaign wins by a mile — that is today's feed.
	if ranked := rankTargets(tally, minTrustedReactors); len(ranked) == 0 || ranked[0].id != "campaign" {
		t.Fatalf("test setup: ungated ranking should favour the campaign, got %v", ranked)
	}

	model, ok := trustGraph(ctx)
	if !ok {
		t.Fatal("installed graph reported unusable")
	}
	ranked := rankTargets(filterToTrusted(ctx, model, tally), minTrustedReactors)
	if len(ranked) != 1 || ranked[0].id != "genuine" {
		t.Fatalf("trust gate produced %v, want only the genuine note", ranked)
	}
}

// Trusted engagement still has to clear the floor: two friends is not a
// popular note, it is two friends.
func TestTrustedEngagementStillNeedsTheFloor(t *testing.T) {
	ctx := context.Background()
	installGraph(t, "friend1", "friend2")

	tally := map[string]map[string]float64{}
	for _, pk := range []string{"friend1", "friend2"} {
		addEngagement(tally, engagement(7, pk, "note", time.Now()))
	}
	for i := 0; i < 50; i++ {
		addEngagement(tally, engagement(7, fmt.Sprintf("bot%d", i), "note", time.Now()))
	}

	model, _ := trustGraph(ctx)
	if ranked := rankTargets(filterToTrusted(ctx, model, tally), minTrustedReactors); len(ranked) != 0 {
		t.Fatalf("a note with %d trusted reactors ranked at a floor of %d: %v",
			2, minTrustedReactors, ranked)
	}
}

// A note left with no trusted engagement at all must leave the map entirely,
// not linger as an empty entry that still counts as a candidate.
func TestFilterToTrustedDropsEmptiedTargets(t *testing.T) {
	ctx := context.Background()
	installGraph(t, "friend1")

	tally := map[string]map[string]float64{}
	addEngagement(tally, engagement(7, "friend1", "kept", time.Now()))
	addEngagement(tally, engagement(7, "stranger", "dropped", time.Now()))

	got := filterToTrusted(ctx, stubWot{members: map[string]bool{"friend1": true}}, tally)
	if _, ok := got["dropped"]; ok {
		t.Error("a note with no trusted engagement survived the filter")
	}
	if len(got["kept"]) != 1 {
		t.Errorf("trusted engagement was lost: %v", got["kept"])
	}
}

// Cold start must withhold the feed, not fall back to the open firehose —
// that fallback is exactly how the spam gets in. It must also withhold before
// paying for a network fetch.
func TestPopularWithholdsFeedUntilGraphIsReady(t *testing.T) {
	fetched := withStubbedFetch(t, 24)
	installEmptyGraph(t)

	notes, err := computePopularNotes(context.Background())
	if err != nil {
		t.Fatalf("computePopularNotes: %v", err)
	}
	if len(notes) != 0 {
		t.Fatalf("an unbuilt trust graph served %d notes", len(notes))
	}
	if *fetched {
		t.Error("withheld the feed but still paid for a network fetch")
	}
}

// Has() answers false both for an untrusted pubkey and for a graph that does
// not exist yet, so usability cannot be read off Has alone.
func TestTrustGraphUsableTellsColdStartFromStrangers(t *testing.T) {
	ctx := context.Background()

	installEmptyGraph(t)
	if _, ok := trustGraph(ctx); ok {
		t.Error("an empty graph reported usable")
	}

	installGraph(t, "friend1", "friend2")
	if _, ok := trustGraph(ctx); !ok {
		t.Error("a populated graph reported unusable")
	}

	// WOT_DEPTH=0: the owner turned the graph off, and Has vouches for
	// everyone. The gate must stand down rather than blank the feed.
	installOpenGraph(t)
	model, ok := trustGraph(ctx)
	if !ok {
		t.Fatal("a deliberately disabled graph blanked the feed")
	}
	tally := map[string]map[string]float64{}
	for i := 0; i < minTrustedReactors; i++ {
		addEngagement(tally, engagement(7, fmt.Sprintf("anyone%d", i), "note", time.Now()))
	}
	if got := filterToTrusted(ctx, model, tally); len(got["note"]) != minTrustedReactors {
		t.Errorf("disabled graph dropped engagement: %v", got)
	}
}
