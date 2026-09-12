//go:build integration

package main

// Live gate for the passive tally. Unit tests prove the bookkeeping; this
// proves the thing actually collects: real seed relays, the real
// ingestPopularEngagement loop, the real snapshot file.
//
//	go test ./ -tags integration -run TestLiveEngagementIngest -v -timeout 5m

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/pkg/wot"
)

func TestLiveEngagementIngest(t *testing.T) {
	const window = 90 * time.Second

	ctx, cancel := context.WithTimeout(context.Background(), window)
	defer cancel()

	pool = nostr.NewSimplePool(ctx, nostr.WithPenaltyBox())
	config.PopularTallyEnabled = true
	config.ImportSeedRelays = []string{
		"wss://relay.primal.net",
		"wss://nos.lol",
		"wss://nostr.mom",
		"wss://nostr-pub.wellorder.net",
	}
	config.PopularTallyCachePath = filepath.Join(t.TempDir(), "popular_tally.json")
	popularTally = newEngagementTally()

	start := time.Now()
	ingestPopularEngagement(ctx) // returns when the context expires
	t.Logf("ran for %s", time.Since(start).Round(time.Second))

	now := time.Now()
	targets, buckets := popularTally.stats(now)
	coverage := popularTally.coverage(now)
	snapshot := popularTally.snapshot(now)

	var engagements int
	for _, reactors := range snapshot {
		engagements += len(reactors)
	}
	t.Logf("targets=%d buckets=%d engagements=%d coverage=%.4f (%.0fs of 24h)",
		targets, buckets, engagements, coverage, coverage*popularWindow.Seconds())

	if targets == 0 {
		t.Fatal("no engagement collected from live relays in 90s — the ingest loop is not collecting")
	}
	if coverage <= 0 {
		t.Fatal("coverage stayed at zero while the subscription was up")
	}
	// The point of the whole exercise: after a short cold start the tally can
	// already answer Popular by itself, because the subscription's own history
	// replay fills the window. If this drops below the floor, the read path
	// falls back to the network and the redesign is buying nothing.
	if coverage < popularTallyMinCoverage {
		t.Errorf("after %s the tally covers only %.2f of the window, under the %.2f floor — Popular would still hit the network",
			window, coverage, popularTallyMinCoverage)
	}

	// And it must produce actual eligible notes, not just raw counters.
	eligible := rankTargets(snapshot, minTrustedReactors)
	t.Logf("eligible notes at %d distinct reactors: %d", minTrustedReactors, len(eligible))
	if len(eligible) == 0 {
		t.Error("no note cleared the distinct-reactor floor — Popular would render empty")
	}

	if _, err := os.Stat(config.PopularTallyCachePath); err != nil {
		t.Fatalf("no snapshot written on shutdown: %v", err)
	}
	restored := newEngagementTally()
	restored.load(config.PopularTallyCachePath, now)
	rt, _ := restored.stats(now)
	t.Logf("snapshot restored %d targets (singletons are deliberately not written)", rt)
}

// Live end-to-end gate for the web-of-trust filter: build the owner's real
// graph off the relays, collect real engagement, and check that what survives
// is both trustworthy and enough to fill a feed.
//
// Needs an owner pubkey to build a graph from; skipped without one:
//
//	HAVEN_TEST_OWNER_PUBKEY=<64-hex> go test ./ -tags integration \
//	    -run TestLiveTrustGate -v -timeout 15m
func TestLiveTrustGateLeavesAUsableFeed(t *testing.T) {
	owner := os.Getenv("HAVEN_TEST_OWNER_PUBKEY")
	if owner == "" {
		t.Skip("set HAVEN_TEST_OWNER_PUBKEY to a 64-hex pubkey to run this")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()

	pool = nostr.NewSimplePool(ctx, nostr.WithPenaltyBox())
	config.PopularTallyEnabled = true
	config.ImportSeedRelays = []string{
		"wss://relay.primal.net",
		"wss://nos.lol",
		"wss://nostr.mom",
		"wss://nostr-pub.wellorder.net",
	}
	config.PopularTallyCachePath = filepath.Join(t.TempDir(), "popular_tally.json")
	popularTally = newEngagementTally()

	// Depth matters a lot here and the two platforms differ: level 2 is the
	// owner's direct follows (the mobile default), level 3 adds their follows
	// (the desktop default). Defaults to the desktop shape; override with
	// HAVEN_TEST_WOT_DEPTH to see what a phone would show.
	depth := 3
	if v := os.Getenv("HAVEN_TEST_WOT_DEPTH"); v != "" {
		if parsed, err := strconv.Atoi(v); err == nil {
			depth = parsed
		}
	}
	model := wot.NewSimpleInMemory(pool, map[string]struct{}{owner: {}},
		config.ImportSeedRelays, depth, 0, 60, filepath.Join(t.TempDir(), "wot.json"), 0)
	graphStart := time.Now()
	wot.Initialize(ctx, model, wot.NewCycle())
	t.Logf("built a depth-%d graph of %d pubkeys in %s", depth, model.Size(), time.Since(graphStart).Round(time.Second))
	if model.Size() == 0 {
		t.Fatal("no graph built — cannot judge the gate")
	}

	ingestCtx, ingestCancel := context.WithTimeout(ctx, 90*time.Second)
	defer ingestCancel()
	ingestPopularEngagement(ingestCtx)

	now := time.Now()
	tally := popularTally.snapshot(now)
	ungated := rankTargets(tally, minTrustedReactors)
	gated := rankTargets(filterToTrusted(ctx, model, tally), minTrustedReactors)
	t.Logf("candidates: %d targets -> %d eligible ungated, %d eligible through the trust gate",
		len(tally), len(ungated), len(gated))

	// The risk of this filter is over-filtering: a feed nobody can read is
	// not an improvement on a feed full of spam.
	if len(gated) < 10 {
		t.Errorf("only %d notes survived the trust gate — the feed would be near-empty", len(gated))
	}

	// Nothing may survive on untrusted engagement.
	for _, r := range gated {
		trusted := 0
		for pk := range tally[r.id] {
			if model.Has(ctx, pk) {
				trusted++
			}
		}
		if trusted < minTrustedReactors {
			t.Fatalf("note %s survived with %d trusted reactors, floor is %d", r.id[:8], trusted, minTrustedReactors)
		}
	}

	// Diagnostic, not an assertion: what share of each list is the campaign
	// that prompted this work. Asserting on its text would tie the suite to
	// one spammer's copy.
	top := func(ranked []scoredTarget, n int) []string {
		ids := []string{}
		for _, r := range ranked {
			if len(ids) == n {
				break
			}
			ids = append(ids, r.id)
		}
		return ids
	}
	for label, ids := range map[string][]string{"ungated": top(ungated, 20), "gated": top(gated, 20)} {
		hits := 0
		for _, ev := range resolveNoteBodies(ctx, ids) {
			if strings.Contains(ev.Content, "In this week's issue") {
				hits++
			}
		}
		t.Logf("%s top 20: %d notes from the 'In this week's issue' campaign", label, hits)
	}
}
