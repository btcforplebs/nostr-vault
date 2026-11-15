//go:build integration

package main

// How long one Underrated refresh takes, and how many notes it gives, on a
// real web of trust and real engagement. Run it on two commits to compare.
// Notes are looked up on the seed relays (no local feed store here), so this
// is the slow case; a phone finds most of them in feedDB.
//
//	HAVEN_TEST_OWNER_PUBKEY=<64-hex> go test ./ -tags integration \
//	    -run TestLiveUnderratedRefreshTime -v -timeout 30m

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/pkg/wot"
)

func TestLiveUnderratedRefreshTime(t *testing.T) {
	owner := os.Getenv("HAVEN_TEST_OWNER_PUBKEY")
	if owner == "" {
		t.Skip("set HAVEN_TEST_OWNER_PUBKEY to a 64-hex pubkey to run this")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Minute)
	defer cancel()

	pool = nostr.NewSimplePool(ctx, nostr.WithPenaltyBox())
	config.PopularTallyEnabled = true
	config.ImportSeedRelays = []string{
		"wss://relay.primal.net",
		"wss://relay.damus.io",
		"wss://relay.snort.social",
		"wss://nostr-pub.wellorder.net",
	}
	config.PopularTallyCachePath = filepath.Join(t.TempDir(), "popular_tally.json")
	popularTally = newEngagementTally()

	model := wot.NewSimpleInMemory(pool, map[string]struct{}{owner: {}},
		config.ImportSeedRelays, 3, 0, 60, filepath.Join(t.TempDir(), "wot.json"), 0)
	graphStart := time.Now()
	wot.Initialize(ctx, model, wot.NewCycle())
	t.Logf("depth-3 graph of %d pubkeys in %s", model.Size(), time.Since(graphStart).Round(time.Second))

	// The first subscription replays the tally's whole window.
	ingestCtx, ingestCancel := context.WithTimeout(ctx, 120*time.Second)
	ingestPopularEngagement(ingestCtx)
	ingestCancel()

	for run := 1; run <= 2; run++ {
		start := time.Now()
		notes, reason, err := computeUnderratedNotes(ctx)
		t.Logf("refresh %d: %d notes in %s (reason %q, err %v)", run, len(notes), time.Since(start).Round(10*time.Millisecond), reason, err)
	}
}
