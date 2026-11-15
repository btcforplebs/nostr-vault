package main

import (
	"context"
	"fmt"
	"path/filepath"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/pkg/wot"
)

// Logen 2026-11-15: Underrated should show more and refresh more. These pin
// the sizes (1,000 candidates, 300 notes, 48h) and the fresh answer.

// The tally keeps two days for Underrated, while Popular still reads one.
func TestTallyKeepsTwoDaysForUnderrated(t *testing.T) {
	now := time.Now()
	tally := newEngagementTally()
	tally.add(engagement(7, "alice", "yesterday", now.Add(-36*time.Hour)), now)
	tally.add(engagement(7, "alice", "today", now.Add(-time.Hour)), now)

	if _, ok := tally.snapshotWithin(now, underratedWindow)["yesterday"]; !ok {
		t.Error("a 36h-old engagement is missing from Underrated's 48h")
	}
	if _, ok := tally.snapshot(now)["yesterday"]; ok {
		t.Error("Popular's 24h snapshot read a 36h-old engagement")
	}
	if got := tally.snapshotWithin(now.Add(13*time.Hour), underratedWindow); len(got) != 1 {
		t.Errorf("49h later Underrated still holds %d targets, want only the 14h-old one", len(got))
	}
}

// Popular's coverage must not be credited with the day before: a tally that
// only knows yesterday has to backfill today.
func TestPopularCoverageIgnoresTheDayBefore(t *testing.T) {
	now := time.Now()
	tally := newEngagementTally()
	for hour := 25; hour < 48; hour++ {
		at := now.Add(-time.Duration(hour)*time.Hour - time.Minute)
		for target := 0; target < popularBucketMinTargets; target++ {
			tally.add(engagement(7, fmt.Sprintf("pk%d-%d", hour, target), fmt.Sprintf("n%d-%d", hour, target), at), now)
		}
	}
	if got := tally.coverage(now); got >= popularTallyMinCoverage {
		t.Fatalf("yesterday's engagement gave Popular %.2f coverage of today", got)
	}
	if got := tally.coverageWithin(now, underratedWindow); got < 0.45 {
		t.Fatalf("Underrated's 48h coverage is %.2f with a full day held, want about half", got)
	}
}

// A cold start replays the whole 48h, so Underrated has two days at once.
func TestIngestFirstPassAsksForTwoDays(t *testing.T) {
	now := time.Now()
	if got, want := int64(ingestSince(0, now)), now.Add(-underratedWindow).Unix(); got != want {
		t.Fatalf("first pass since %d, want %d (48h)", got, want)
	}
}

// Up to 300 notes, still 2 per author.
func TestUnderratedListsUpToThreeHundred(t *testing.T) {
	now := time.Now()
	tally := map[string]map[string]float64{}
	var events []*nostr.Event
	for i := 0; i < 400; i++ {
		id := fmt.Sprintf("note%03d", i)
		events = append(events, &nostr.Event{ID: id, PubKey: fmt.Sprintf("author%03d", i), CreatedAt: nostr.Timestamp(now.Unix()), Kind: 1})
		tally[id] = dvmReactors(id+"-", 3)
	}
	if got := len(scoreUnderrated(events, tally, underratedInputs{oneStepOut: anyOneStepOut}, now)); got != 300 {
		t.Fatalf("listed %d notes from 400 qualifying, want 300", got)
	}
}

// 1,000 of the most engaged ids are looked up.
func TestUnderratedLooksAtAThousandCandidates(t *testing.T) {
	tally := map[string]map[string]float64{}
	for i := 0; i < 1200; i++ {
		tally[fmt.Sprintf("t%04d", i)] = dvmReactors(fmt.Sprintf("t%04d-", i), 3)
	}
	if got := len(underratedCandidates(tally)); got != 1000 {
		t.Fatalf("%d candidates, want 1000", got)
	}
}

// Reach and WebShape make stubWot a whole web for Underrated (the wot
// instance is an atomic.Value, so every test must install the same type):
// everyone allowed is one step out with one vouch.
func (s stubWot) Reach(pk string) (int, bool, bool) { return 1, false, s.Has(context.Background(), pk) }
func (s stubWot) WebShape() (int, int, int)         { return 3, 1, 5 }

// Every ask is fresh: a note that qualified a moment after the last answer is
// in the next one (it used to wait out a 60s-5min cached answer).
func TestUnderratedIsComputedFreshEveryTime(t *testing.T) {
	now := time.Now()
	savedTally, savedPool, savedRelays, savedFetch := popularTally, pool, config.ImportSeedRelays, fetchEngagementInto
	savedFeed, savedOut, savedIn, savedPriv := feedDB, outboxDB, inboxDB, privateDB
	t.Cleanup(func() {
		popularTally, pool, config.ImportSeedRelays, fetchEngagementInto = savedTally, savedPool, savedRelays, savedFetch
		feedDB, outboxDB, inboxDB, privateDB = savedFeed, savedOut, savedIn, savedPriv
	})
	popularTally = newEngagementTally()
	pool, config.ImportSeedRelays = nil, nil
	fetchEngagementInto = func(context.Context, map[string]map[string]float64, time.Duration) error { return nil }
	wot.MarkReady(wot.NewCycle(), stubWot{allow: true})
	db := fallbackBackend(filepath.Join(t.TempDir(), "feed"))
	if err := db.Init(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	feedDB, outboxDB, inboxDB, privateDB = db, nil, nil, nil

	post := func(n int) {
		author := newTestKey(t)
		ev := author.sign(t, nostr.Event{Kind: 1, Content: fmt.Sprintf("note %d", n), CreatedAt: nostr.Timestamp(now.Add(-time.Hour).Unix())})
		saveEv(t, db, ev)
		for r := 0; r < 3; r++ {
			popularTally.add(&nostr.Event{Kind: 7, PubKey: fmt.Sprintf("reactor%d-%d", n, r), CreatedAt: nostr.Timestamp(now.Add(-30 * time.Minute).Unix()), Tags: nostr.Tags{{"e", ev.ID}}}, now)
		}
	}

	post(1)
	first, _, err := computeUnderratedNotes(context.Background())
	if err != nil || len(first) != 1 {
		t.Fatalf("first answer: %d notes, err %v; want 1", len(first), err)
	}
	post(2)
	second, _, err := computeUnderratedNotes(context.Background())
	if err != nil || len(second) != 2 {
		t.Fatalf("second answer: %d notes, err %v; want 2 (a cached answer hid the new note)", len(second), err)
	}
}
