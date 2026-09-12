package main

import (
	"context"
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/pkg/wot"
)

func engagement(kind int, reactor, target string, at time.Time) *nostr.Event {
	return &nostr.Event{
		Kind:      kind,
		PubKey:    reactor,
		Tags:      nostr.Tags{{"e", target}},
		CreatedAt: nostr.Timestamp(at.Unix()),
	}
}

// randomEngagementSet builds a spread of events across the whole window, with
// repeat reactors, mixed kinds, and notes both over and under the floor.
func randomEngagementSet(now time.Time, n int) []*nostr.Event {
	rng := rand.New(rand.NewSource(1))
	kinds := []int{7, 6, 9735}
	events := make([]*nostr.Event, 0, n)
	for i := 0; i < n; i++ {
		target := fmt.Sprintf("note%d", rng.Intn(40))
		reactor := fmt.Sprintf("pk%d", rng.Intn(25))
		age := time.Duration(rng.Intn(23*60)) * time.Minute
		events = append(events, engagement(kinds[rng.Intn(len(kinds))], reactor, target, now.Add(-age)))
	}
	return events
}

// THE load-bearing test: splitting the 24h window into hour buckets must not
// change a single score. Same events, two paths — the batch map dvm.go builds
// and a merged snapshot of the bucketed tally — must rank identically.
//
// Mutation-checked: raising popularBucketSpan handling to file everything in
// one bucket keeps this green (correctly — that is still equivalent), but
// changing snapshot's merge from "strongest weight wins" to "last write wins"
// or "sum" makes it fail, which is the drift it exists to catch.
func TestTallyRankingMatchesBatch(t *testing.T) {
	now := time.Now()
	events := randomEngagementSet(now, 3000)

	batch := map[string]map[string]float64{}
	for _, ev := range events {
		addEngagement(batch, ev)
	}

	tally := newEngagementTally()
	for _, ev := range events {
		tally.add(ev, now)
	}
	merged := tally.snapshot(now)

	if !reflect.DeepEqual(batch, merged) {
		t.Fatalf("bucketed tally disagrees with batch map:\n%d targets vs %d", len(batch), len(merged))
	}

	wantRanked := rankTargets(batch, minTrustedReactors)
	gotRanked := rankTargets(merged, minTrustedReactors)
	if !reflect.DeepEqual(wantRanked, gotRanked) {
		t.Fatalf("ranking differs: batch %v vs tally %v", wantRanked, gotRanked)
	}
	if len(wantRanked) == 0 {
		t.Fatal("test data produced no eligible notes — it would pass vacuously")
	}
}

// Arrival order is not something a live subscription controls: relays replay
// at different offsets and reconnects re-deliver. Feeding the same events in a
// different order must produce the same tally.
func TestTallyIsOrderIndependent(t *testing.T) {
	now := time.Now()
	events := randomEngagementSet(now, 1500)

	forward := newEngagementTally()
	for _, ev := range events {
		forward.add(ev, now)
	}
	backward := newEngagementTally()
	for i := len(events) - 1; i >= 0; i-- {
		backward.add(events[i], now)
	}

	if !reflect.DeepEqual(forward.snapshot(now), backward.snapshot(now)) {
		t.Fatal("tally depends on the order events arrive in")
	}
}

// Anything older than the window is dropped, and the drop is by clock hour so
// the edge is exact rather than approximate.
func TestTallyEvictsOutsideWindow(t *testing.T) {
	now := time.Now()
	tally := newEngagementTally()

	tally.add(engagement(7, "alice", "fresh", now.Add(-time.Minute)), now)
	tally.add(engagement(7, "alice", "old", now.Add(-23*time.Hour)), now)

	if got := tally.snapshot(now); len(got) != 2 {
		t.Fatalf("before the roll: %d targets, want 2", len(got))
	}

	// Two hours later the 23h-old engagement is outside the window.
	later := now.Add(2 * time.Hour)
	got := tally.snapshot(later)
	if _, ok := got["old"]; ok {
		t.Error("engagement older than the window survived the roll")
	}
	if _, ok := got["fresh"]; !ok {
		t.Error("engagement inside the window was evicted")
	}
}

// created_at is attacker-controlled. A note stamped into next week must not be
// filed in a bucket the window never reaches.
func TestTallyRejectsSkewedTimestamps(t *testing.T) {
	now := time.Now()
	tally := newEngagementTally()

	tally.add(engagement(7, "alice", "future", now.Add(7*24*time.Hour)), now)
	tally.add(engagement(7, "alice", "ancient", now.Add(-72*time.Hour)), now)
	tally.add(engagement(7, "alice", "ok", now.Add(-time.Minute)), now)

	got := tally.snapshot(now)
	if _, ok := got["future"]; ok {
		t.Error("a future-dated engagement was accepted")
	}
	if _, ok := got["ancient"]; ok {
		t.Error("an engagement older than the window was accepted")
	}
	if _, ok := got["ok"]; !ok {
		t.Error("a valid engagement was rejected")
	}
}

// Coverage measures how long the subscription was actually up. A process that
// was asleep for hours between two marks must not claim that time as watched —
// otherwise a phone would skip the backfill it needs.
func TestCoverageCreditsOnlyConnectedTime(t *testing.T) {
	base := time.Now().Truncate(time.Hour).Add(30 * time.Minute)
	tally := newEngagementTally()

	tally.markAlive(base)
	tally.markAlive(base.Add(6 * time.Hour)) // long sleep: capped, not credited

	if got := tally.coverage(base.Add(6 * time.Hour)); got > popularCoverageMaxStep.Seconds()/popularWindow.Seconds()+1e-9 {
		t.Fatalf("a six-hour gap was credited as coverage: %.4f", got)
	}

	// A steady stream of marks accrues real coverage.
	steady := newEngagementTally()
	at := base
	for i := 0; i < 120; i++ { // one hour of 30s marks
		steady.markAlive(at)
		at = at.Add(popularCoverageMarkEvery)
	}
	got := steady.coverage(at)
	want := time.Hour.Seconds() / popularWindow.Seconds()
	if got < want*0.9 || got > want*1.1 {
		t.Fatalf("one hour of marks gave coverage %.4f, want about %.4f", got, want)
	}
}

// No bucket may record more than the hour it covers, however many marks land.
func TestCoverageCannotExceedTheHour(t *testing.T) {
	base := time.Now().Truncate(time.Hour)
	tally := newEngagementTally()
	at := base
	for i := 0; i < 500; i++ {
		tally.markAlive(at)
		at = at.Add(time.Second)
	}
	tally.mu.Lock()
	defer tally.mu.Unlock()
	if got := tally.covered[bucketIndex(base)]; got > popularBucketSpan.Seconds() {
		t.Fatalf("bucket recorded %.0f seconds of coverage in a %.0f second hour", got, popularBucketSpan.Seconds())
	}
}

// The snapshot file exists so Popular is not empty after a relaunch. What it
// must preserve is the ranking, not every byte: singletons are deliberately
// dropped.
func TestSnapshotRoundTripPreservesRanking(t *testing.T) {
	now := time.Now()
	path := filepath.Join(t.TempDir(), "popular_tally.json")

	original := newEngagementTally()
	for _, ev := range randomEngagementSet(now, 2000) {
		original.add(ev, now)
	}
	original.markAlive(now.Add(-time.Minute))
	original.markAlive(now)

	if err := original.save(path, now); err != nil {
		t.Fatalf("save: %v", err)
	}

	restored := newEngagementTally()
	restored.load(path, now)

	want := rankTargets(original.snapshot(now), minTrustedReactors)
	got := rankTargets(restored.snapshot(now), minTrustedReactors)
	if len(want) == 0 {
		t.Fatal("test data produced no eligible notes — it would pass vacuously")
	}
	if !reflect.DeepEqual(want, got) {
		t.Fatalf("ranking changed across a save/load:\nwant %v\ngot  %v", want, got)
	}
}

// A snapshot written yesterday must not resurrect yesterday's popularity.
func TestSnapshotLoadDropsStaleBuckets(t *testing.T) {
	now := time.Now()
	path := filepath.Join(t.TempDir(), "popular_tally.json")

	old := newEngagementTally()
	for i := 0; i < 6; i++ {
		old.add(engagement(7, fmt.Sprintf("pk%d", i), "yesterday", now.Add(-time.Hour)), now)
	}
	if err := old.save(path, now); err != nil {
		t.Fatalf("save: %v", err)
	}

	// Reload a full day later.
	restored := newEngagementTally()
	restored.load(path, now.Add(25*time.Hour))
	if got := restored.snapshot(now.Add(25 * time.Hour)); len(got) != 0 {
		t.Fatalf("stale buckets survived the reload: %v", got)
	}
}

// A truncated or corrupt file must leave the tally usable and empty, not panic
// and not half-load: the read path backfills from the network in that case.
func TestSnapshotLoadToleratesGarbage(t *testing.T) {
	now := time.Now()
	dir := t.TempDir()
	path := filepath.Join(dir, "popular_tally.json")
	if err := os.WriteFile(path, []byte(`{"buckets":{"1":{"note`), 0o644); err != nil {
		t.Fatal(err)
	}

	tally := newEngagementTally()
	tally.load(path, now)
	if got := tally.snapshot(now); len(got) != 0 {
		t.Fatalf("garbage file produced %d targets", len(got))
	}
	tally.add(engagement(7, "alice", "note1", now), now)
	if got := tally.snapshot(now); len(got) != 1 {
		t.Fatal("tally unusable after loading a corrupt snapshot")
	}
}

// The ceiling must shed the notes that cannot win — targets one person
// touched — and keep the ones that can. It also has to be a ceiling on the
// whole window: an earlier version capped each hour bucket, which bounded
// nothing, because 24 buckets each just under the cap hold 24 times what the
// number claims.
func TestCeilingDropsSingletonsAndBoundsTheWindow(t *testing.T) {
	now := time.Now()
	tally := newEngagementTally()

	// A contender: six distinct reactors, comfortably over the floor.
	for i := 0; i < 6; i++ {
		tally.add(engagement(7, fmt.Sprintf("fan%d", i), "contender", now), now)
	}
	// Then flood every hour of the window with singletons, well past the cap.
	for i := 0; i < popularMaxTargets*2; i++ {
		at := now.Add(-time.Duration(i%24) * time.Hour).Add(-time.Minute)
		tally.add(engagement(7, fmt.Sprintf("drive%d", i), fmt.Sprintf("junk%d", i), at), now)
	}

	got := tally.snapshot(now)
	if _, ok := got["contender"]; !ok {
		t.Fatal("the multi-reactor note was evicted by a flood of singletons")
	}
	if len(got) > popularMaxTargets {
		t.Fatalf("tally holds %d targets across the window, past the %d ceiling", len(got), popularMaxTargets)
	}
}

// The bookkeeping counter behind that ceiling must track what is really held.
// If it drifts up, the tally throttles itself early and stops collecting; if it
// drifts down, the ceiling stops being one.
func TestTotalTracksHeldTargets(t *testing.T) {
	now := time.Now()
	tally := newEngagementTally()
	for _, ev := range randomEngagementSet(now, 4000) {
		tally.add(ev, now)
	}
	check := func(when string, at time.Time) {
		t.Helper()
		held := len(tally.snapshot(at))
		tally.mu.Lock()
		counted := 0
		for _, bucket := range tally.buckets {
			counted += len(bucket)
		}
		total := tally.total
		tally.mu.Unlock()
		if total != counted {
			t.Fatalf("%s: counter says %d target entries, buckets hold %d", when, total, counted)
		}
		if held > total {
			t.Fatalf("%s: %d distinct targets from %d entries", when, held, total)
		}
	}
	check("after fill", now)
	check("after a 12h roll", now.Add(12*time.Hour))
	check("after the window rolls fully", now.Add(25*time.Hour))
}

// engagementWeight is the single definition both paths score from; if it drifts
// the anti-gaming ordering (zap > repost > like) goes with it.
func TestEngagementWeightOrdering(t *testing.T) {
	if !(engagementWeight(9735) > engagementWeight(6) && engagementWeight(6) > engagementWeight(7)) {
		t.Fatal("zap > repost > reaction no longer holds")
	}
	for _, kind := range []int{0, 1, 3, 30023, 1063} {
		if engagementWeight(kind) != 0 {
			t.Errorf("kind %d scored %v, want 0", kind, engagementWeight(kind))
		}
	}
}

// A cold start collects most of a day inside the first minute, because relays
// replay history when the subscription opens with a 24h `since`. Coverage must
// see that data even though the process has almost no uptime — otherwise the
// read path pays for a network fetch to re-collect what it is already holding.
func TestCoverageCountsReplayedHistory(t *testing.T) {
	now := time.Now()
	tally := newEngagementTally()

	// One minute of "uptime", 24 hours of replayed engagement.
	tally.markAlive(now.Add(-time.Minute))
	tally.markAlive(now)
	for hour := 0; hour < 24; hour++ {
		at := now.Add(-time.Duration(hour)*time.Hour - time.Minute)
		for target := 0; target < popularBucketMinTargets; target++ {
			tally.add(engagement(7, fmt.Sprintf("pk%d-%d", hour, target), fmt.Sprintf("note%d-%d", hour, target), at), now)
		}
	}

	if got := tally.coverage(now); got < popularTallyMinCoverage {
		t.Fatalf("a tally holding 24h of replayed engagement reported %.2f coverage, under the %.2f floor", got, popularTallyMinCoverage)
	}
}

// The data measure must not be satisfied by a scatter of stray events, or a
// device that saw almost nothing would answer Popular from almost nothing.
func TestSparseDataDoesNotClaimCoverage(t *testing.T) {
	now := time.Now()
	tally := newEngagementTally()
	for hour := 0; hour < 24; hour++ {
		at := now.Add(-time.Duration(hour)*time.Hour - time.Minute)
		tally.add(engagement(7, fmt.Sprintf("pk%d", hour), fmt.Sprintf("note%d", hour), at), now)
	}
	if got := tally.coverage(now); got >= popularTallyMinCoverage {
		t.Fatalf("one event per hour claimed %.2f coverage", got)
	}
}

// A reconnect must resume from the newest event already seen, not re-request
// the whole window — but a watermark that has aged out of the window must fall
// back to the window start, or a device that was off for two days would resume
// from a point the tally can no longer hold.
func TestIngestSinceResumesFromWatermark(t *testing.T) {
	now := time.Now()
	windowStart := now.Add(-popularWindow).Unix()

	if got := ingestSince(0, now); int64(got) != windowStart {
		t.Errorf("first pass resumed at %d, want the window start %d", got, windowStart)
	}
	recent := now.Add(-5 * time.Minute).Unix()
	if got := ingestSince(recent, now); int64(got) != recent {
		t.Errorf("reconnect resumed at %d, want the watermark %d", got, recent)
	}
	stale := now.Add(-48 * time.Hour).Unix()
	if got := ingestSince(stale, now); int64(got) != windowStart {
		t.Errorf("stale watermark resumed at %d, want the window start %d", got, windowStart)
	}
}

// The tally is written by the ingest loop and read by whichever thread opened
// the Popular tab, while a ticker snapshots it to disk. Run all three at once
// under -race; an unsynchronised map here is a hard crash in production, not a
// wrong answer.
func TestTallyConcurrentAccess(t *testing.T) {
	now := time.Now()
	tally := newEngagementTally()
	path := filepath.Join(t.TempDir(), "popular_tally.json")

	var wg sync.WaitGroup
	for writer := 0; writer < 4; writer++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			for i := 0; i < 500; i++ {
				tally.add(engagement(7, fmt.Sprintf("pk%d-%d", w, i%20), fmt.Sprintf("note%d", i%50), now), now)
				tally.markAlive(now)
			}
		}(writer)
	}
	for reader := 0; reader < 2; reader++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 200; i++ {
				_ = rankTargets(tally.snapshot(now), minTrustedReactors)
				_ = tally.coverage(now)
				tally.stats(now)
			}
		}()
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < 20; i++ {
			if err := tally.save(path, now); err != nil {
				t.Errorf("save under concurrent load: %v", err)
				return
			}
		}
	}()
	wg.Wait()

	if got := len(tally.snapshot(now)); got != 50 {
		t.Fatalf("concurrent writers produced %d targets, want 50", got)
	}
}

// Popular must be answered from the tally alone once it covers the window —
// no network call at all. The stub records whether the read path reached for
// one, because "no error" alone cannot tell a local answer apart from a failed
// fetch whose error was swallowed.
func TestPopularServesLocallyWithoutFetching(t *testing.T) {
	fetched := withStubbedFetch(t, 24) // a full window of engagement
	if _, err := computePopularNotes(context.Background()); err != nil {
		t.Fatalf("computePopularNotes: %v", err)
	}
	if *fetched {
		t.Fatal("a fully covered tally still fetched engagement from the network")
	}
}

// And the other half of the gate: a tally that covers almost nothing must
// backfill, or a phone the OS keeps suspending would rank a day of nostr from
// the ten minutes it happened to be awake.
func TestThinTallyBackfillsFromNetwork(t *testing.T) {
	fetched := withStubbedFetch(t, 1) // one hour of engagement, far under the floor
	if _, err := computePopularNotes(context.Background()); err != nil {
		t.Fatalf("computePopularNotes: %v", err)
	}
	if !*fetched {
		t.Fatal("a tally covering one hour of the window answered without backfilling")
	}
}

// withStubbedFetch points the read path at a stub, fills the tally with
// `hours` of eligible engagement, and restores every global it touched.
// Returns the flag the stub sets.
func withStubbedFetch(t *testing.T, hours int) *bool {
	t.Helper()
	now := time.Now()

	savedTally, savedPool, savedRelays := popularTally, pool, config.ImportSeedRelays
	savedFetch := fetchEngagementInto
	t.Cleanup(func() {
		popularTally, pool, config.ImportSeedRelays = savedTally, savedPool, savedRelays
		fetchEngagementInto = savedFetch
		popularCacheMu.Lock()
		popularCache, popularCacheExpiry = nil, time.Time{}
		popularCacheMu.Unlock()
	})

	popularTally = newEngagementTally()
	pool = nil
	config.ImportSeedRelays = nil
	// Install a graph explicitly: the wot instance is process-wide and other
	// test files install their own, so inheriting whatever ran first makes
	// these tests pass or fail on ordering rather than on the code.
	wot.MarkReady(wot.NewCycle(), stubWot{allow: true})
	popularCacheMu.Lock()
	popularCache, popularCacheExpiry = nil, time.Time{}
	popularCacheMu.Unlock()

	fetched := false
	fetchEngagementInto = func(context.Context, map[string]map[string]float64) error {
		fetched = true
		return nil
	}

	for hour := 0; hour < hours; hour++ {
		at := now.Add(-time.Duration(hour)*time.Hour - time.Minute)
		for target := 0; target < popularBucketMinTargets; target++ {
			for reactor := 0; reactor < minTrustedReactors+1; reactor++ {
				tgt := fmt.Sprintf("note%d-%d", hour, target)
				popularTally.add(engagement(7, fmt.Sprintf("pk%d", reactor), tgt, at), now)
			}
		}
	}
	return &fetched
}
