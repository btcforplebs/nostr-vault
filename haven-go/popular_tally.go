package main

// Passive popularity tally.
//
// The Popular feed used to exist only as a pull: every time the tab was opened
// past its cache, computePopularNotes fired a fresh REQ at the seed relays for
// the last 24h of kinds 7/6/9735 and scored whatever came back. That has a
// ceiling nothing in our code can raise — relays cap a REQ's response, and the
// ones we ship with return roughly the last half hour however large a Limit we
// ask for. The 24h window was aspirational, not real.
//
// This file makes the always-on relay do the collecting instead: a live
// subscription feeds a rolling 24h tally, so Popular reads state we have been
// accumulating rather than a snapshot a relay was willing to hand over. On a
// Mac left running that converges to no outbound query at all; on a phone,
// where the OS suspends the process, the tally only advances while the app is
// foregrounded, so dvm.go still backfills from the network when coverage is
// thin (see popularTallyMinCoverage).
//
// Only the collection changes. The scoring rules stay in dvm.go and are used
// unchanged — TestTallyRankingMatchesBatch pins that.

import (
	"context"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

const (
	// How far back the tally scores. Matches the window dvm.go's fetch asks
	// for, so the two paths remain comparable.
	popularWindow = 24 * time.Hour

	// A bucket is one clock hour of engagement. Eviction is then dropping a
	// map, not scanning one, and the window edge is exact.
	popularBucketSpan = time.Hour

	// Ceiling on targets held across the whole window, not per bucket: a
	// per-bucket cap bounds nothing useful, because 24 buckets each under it
	// still add up to 24 times the number you thought you had allowed.
	//
	// Measured cost of the real thing: a full day off the shipped seed relays
	// is ~12.3k engagements over ~3.6k targets, which the tally holds in 4 MB
	// (10x that: 40 MB). 25k targets is roughly 7x the observed load and about
	// 29 MB — headroom for a much busier relay set while staying an order of
	// magnitude under the long-form bodies that made this app a jetsam target.
	popularMaxTargets = 25_000

	// Fraction of the last 24h the tally must cover before Popular is answered
	// from local state alone. Below it, dvm.go adds a network fetch on top of
	// whatever the tally holds.
	popularTallyMinCoverage = 0.5

	// Targets an hour bucket must hold before that hour counts as covered by
	// the data rather than by uptime. Small enough that a quiet hour still
	// counts, large enough that one stray replayed event does not.
	popularBucketMinTargets = 5

	// Longest gap credited as "connected" between two liveness marks. A gap
	// larger than this is downtime, not coverage — without the cap a process
	// that slept for six hours would wake up and claim it had been watching.
	popularCoverageMaxStep = 90 * time.Second

	// How often the ingest loop marks itself alive while idle. Well under the
	// cap above, so a healthy but quiet subscription still accrues coverage.
	popularCoverageMarkEvery = 30 * time.Second

	// Events dated further ahead than this are ignored. created_at is
	// attacker-controlled: without the guard a note stamped a year out would
	// sit in a bucket the window never evicts.
	popularMaxClockSkew = 10 * time.Minute
)

// engagementTally is a rolling 24h record of who engaged with what.
//
// Shape inside a bucket is deliberately identical to the map dvm.go's batch
// path builds (target -> reactor -> that reactor's strongest weight) so the
// existing scoring functions consume a merged snapshot with no adaptation.
//
// Reactor pubkeys are stored as full hex, not truncated. An earlier draft
// keyed them by the first 8 bytes to save memory; that silently weakens
// scoreExcludingAuthor, which excludes a note's own author by comparing that
// key — a truncation collision would drop a real reactor's weight or, worse,
// let an author's own engagement pass as somebody else's. Interning the
// strings gets most of the memory back without touching the comparison.
type engagementTally struct {
	mu      sync.Mutex
	buckets map[int64]map[string]map[string]float64 // bucket index -> target -> reactor -> weight
	covered map[int64]float64                       // bucket index -> seconds connected
	intern  map[string]string                       // one backing string per distinct pubkey
	lastMk  time.Time                               // last liveness mark
	total   int                                     // target entries across all buckets
}

var popularTally = newEngagementTally()

func newEngagementTally() *engagementTally {
	return &engagementTally{
		buckets: make(map[int64]map[string]map[string]float64),
		covered: make(map[int64]float64),
		intern:  make(map[string]string),
	}
}

// bucketIndex is the clock-hour an instant falls in.
func bucketIndex(t time.Time) int64 { return t.Unix() / int64(popularBucketSpan/time.Second) }

// intern returns a shared instance of s. Caller holds the lock.
func (t *engagementTally) internLocked(s string) string {
	if existing, ok := t.intern[s]; ok {
		return existing
	}
	t.intern[s] = s
	return s
}

// add records one engagement event, or ignores it. Mirrors addEngagement's
// rules (same kinds, same weights, strongest-wins per reactor) but files the
// entry in the bucket its created_at falls in.
func (t *engagementTally) add(ev *nostr.Event, now time.Time) {
	if ev == nil {
		return
	}
	weight := engagementWeight(ev.Kind)
	if weight == 0 {
		return
	}
	target := reactionTargetID(ev.Tags)
	if target == "" {
		return
	}
	at := ev.CreatedAt.Time()
	if at.After(now.Add(popularMaxClockSkew)) || at.Before(now.Add(-popularWindow)) {
		return
	}

	t.mu.Lock()
	defer t.mu.Unlock()

	idx := bucketIndex(at)
	bucket := t.buckets[idx]
	if bucket == nil {
		bucket = make(map[string]map[string]float64)
		t.buckets[idx] = bucket
	}
	reactors := bucket[target]
	if reactors == nil {
		if t.total >= popularMaxTargets && !t.dropSingletonsLocked() {
			return // nothing left to shed but real candidates; do not grow
		}
		reactors = make(map[string]float64, 1)
		bucket[t.internLocked(target)] = reactors
		t.total++
	}
	if pk := t.internLocked(ev.PubKey); weight > reactors[pk] {
		reactors[pk] = weight
	}
}

// dropSingletonsLocked frees room by discarding targets only one person
// engaged with, oldest hour first. Those are ~78% of the map and cannot reach
// minTrustedReactors before their hour rolls out of the window anyway.
// Reports whether it freed anything.
func (t *engagementTally) dropSingletonsLocked() bool {
	indexes := make([]int64, 0, len(t.buckets))
	for idx := range t.buckets {
		indexes = append(indexes, idx)
	}
	sort.Slice(indexes, func(i, j int) bool { return indexes[i] < indexes[j] })

	freed := false
	for _, idx := range indexes {
		bucket := t.buckets[idx]
		for target, reactors := range bucket {
			if len(reactors) <= 1 {
				delete(bucket, target)
				t.total--
				freed = true
			}
		}
		// One hour's singletons is usually plenty; stopping early keeps the
		// newest hours intact, which is where the next winners come from.
		if freed {
			break
		}
	}
	return freed
}

// markAlive credits the time since the previous mark as connected, up to
// popularCoverageMaxStep. The ingest loop calls it on every event and on a
// ticker, so coverage measures socket uptime rather than traffic volume — a
// quiet hour with a healthy subscription still counts as watched.
func (t *engagementTally) markAlive(now time.Time) {
	t.mu.Lock()
	defer t.mu.Unlock()
	last := t.lastMk
	t.lastMk = now
	if last.IsZero() {
		return
	}
	step := now.Sub(last)
	if step <= 0 {
		return
	}
	if step > popularCoverageMaxStep {
		step = popularCoverageMaxStep
	}
	idx := bucketIndex(now)
	if seconds := t.covered[idx] + step.Seconds(); seconds < popularBucketSpan.Seconds() {
		t.covered[idx] = seconds
	} else {
		t.covered[idx] = popularBucketSpan.Seconds()
	}
	t.pruneLocked(now)
}

// pruneLocked drops buckets that have fallen out of the window.
func (t *engagementTally) pruneLocked(now time.Time) {
	oldest := bucketIndex(now.Add(-popularWindow))
	for idx, bucket := range t.buckets {
		if idx < oldest {
			t.total -= len(bucket)
			delete(t.buckets, idx)
		}
	}
	for idx := range t.covered {
		if idx < oldest {
			delete(t.covered, idx)
		}
	}
	// Interned strings for evicted buckets are unreachable but still held by
	// the intern table; rebuild it from what survives rather than letting it
	// grow for the process lifetime.
	if len(t.intern) > 4*popularMaxTargets {
		t.rebuildInternLocked()
	}
}

func (t *engagementTally) rebuildInternLocked() {
	fresh := make(map[string]string, len(t.intern)/2)
	for _, bucket := range t.buckets {
		for target, reactors := range bucket {
			fresh[target] = target
			for pk := range reactors {
				fresh[pk] = pk
			}
		}
	}
	t.intern = fresh
}

// snapshot merges the live buckets into one target -> reactor -> weight map of
// the shape dvm.go scores. A reactor who engaged in several hours contributes
// once, at their strongest weight — the same rule addEngagement applies within
// a single batch, so splitting the window into buckets cannot change a score.
func (t *engagementTally) snapshot(now time.Time) map[string]map[string]float64 {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.pruneLocked(now)

	merged := make(map[string]map[string]float64)
	for _, bucket := range t.buckets {
		for target, reactors := range bucket {
			into := merged[target]
			if into == nil {
				into = make(map[string]float64, len(reactors))
				merged[target] = into
			}
			for pk, w := range reactors {
				if w > into[pk] {
					into[pk] = w
				}
			}
		}
	}
	return merged
}

// coverage is how much of the last 24h the tally can actually speak for,
// which is the larger of two measures:
//
//   - uptime: how long the ingest loop held a subscription;
//   - data: how many of the 24 hour buckets hold real engagement.
//
// The second exists because relays replay history when a subscription opens
// with a 24h `since` — a cold start on a phone collects most of a day inside
// the first minute. Measured live: 90 seconds of ingestion filled all 24
// buckets with 12k engagements. Scoring uptime alone would have declared that
// tally 0.1% covered and sent it to the network for data it was already
// holding, which is the very query this work exists to remove.
func (t *engagementTally) coverage(now time.Time) float64 {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.pruneLocked(now)

	var seconds float64
	for _, s := range t.covered {
		seconds += s
	}
	uptime := seconds / popularWindow.Seconds()

	populated := 0
	for _, bucket := range t.buckets {
		if len(bucket) >= popularBucketMinTargets {
			populated++
		}
	}
	data := float64(populated) / float64(popularWindow/popularBucketSpan)
	if data > 1 {
		data = 1
	}

	if data > uptime {
		return data
	}
	return uptime
}

// stats reports what the tally is holding, for logging.
func (t *engagementTally) stats(now time.Time) (targets int, buckets int) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.pruneLocked(now)
	seen := make(map[string]struct{})
	for _, bucket := range t.buckets {
		for target := range bucket {
			seen[target] = struct{}{}
		}
	}
	return len(seen), len(t.buckets)
}

// engagementWeight is the score one reactor's strongest action is worth. Single
// definition, shared by the batch path (addEngagement) and the tally, so the
// two cannot drift apart.
func engagementWeight(kind int) float64 {
	switch kind {
	case 7:
		return 1.0 // reaction
	case 6:
		return 2.0 // repost
	case 9735:
		return 3.0 // zap
	default:
		return 0
	}
}

// ---------------------------------------------------------------------------
// Persistence
// ---------------------------------------------------------------------------

// tallySnapshotFile is the on-disk form. Buckets are keyed by index so a
// reload lands in exactly the hours the events belong to, and anything outside
// the window is discarded on load — which is also what keeps the file from
// growing: it is rewritten, never appended.
type tallySnapshotFile struct {
	SavedAt int64                                   `json:"saved_at"`
	Buckets map[int64]map[string]map[string]float64 `json:"buckets"`
	Covered map[int64]float64                       `json:"covered"`
}

// save writes the tally so a relaunch does not start from nothing. Targets
// only one person ever engaged with are left out: they are most of the map and
// none of the answer.
//
// "Only one person" is counted across the whole window, not per bucket. A
// first draft filtered each bucket on its own and quietly discarded exactly
// the notes Popular exists for — a note with six reactors spread over six
// hours has one reactor in each hour, so every bucket looked like a singleton
// and the whole note vanished from the file. The round-trip ranking test
// caught it.
func (t *engagementTally) save(path string, now time.Time) error {
	t.mu.Lock()
	t.pruneLocked(now)

	windowReactors := make(map[string]map[string]struct{})
	for _, bucket := range t.buckets {
		for target, reactors := range bucket {
			seen := windowReactors[target]
			if seen == nil {
				seen = make(map[string]struct{}, len(reactors))
				windowReactors[target] = seen
			}
			for pk := range reactors {
				seen[pk] = struct{}{}
			}
		}
	}

	out := tallySnapshotFile{
		SavedAt: now.Unix(),
		Buckets: make(map[int64]map[string]map[string]float64, len(t.buckets)),
		Covered: make(map[int64]float64, len(t.covered)),
	}
	for idx, bucket := range t.buckets {
		kept := make(map[string]map[string]float64)
		for target, reactors := range bucket {
			if len(windowReactors[target]) < 2 {
				continue
			}
			copied := make(map[string]float64, len(reactors))
			for pk, w := range reactors {
				copied[pk] = w
			}
			kept[target] = copied
		}
		if len(kept) > 0 {
			out.Buckets[idx] = kept
		}
	}
	for idx, s := range t.covered {
		out.Covered[idx] = s
	}
	t.mu.Unlock()

	data, err := json.Marshal(out)
	if err != nil {
		return err
	}
	// Write-then-rename: a snapshot truncated by a kill would otherwise be
	// unparseable on the next launch, and the tally would silently start empty.
	tmp := path + ".tmp"
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// load restores a saved tally, dropping anything now outside the window.
// A missing or unreadable file is not an error: the tally simply starts empty
// and the read path backfills from the network until coverage recovers.
func (t *engagementTally) load(path string, now time.Time) {
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var in tallySnapshotFile
	if err := json.Unmarshal(data, &in); err != nil {
		log.Printf("popular: ignoring unreadable tally snapshot: %v", err)
		return
	}

	t.mu.Lock()
	defer t.mu.Unlock()
	oldest := bucketIndex(now.Add(-popularWindow))
	for idx, bucket := range in.Buckets {
		if idx < oldest {
			continue
		}
		into := t.buckets[idx]
		if into == nil {
			into = make(map[string]map[string]float64, len(bucket))
			t.buckets[idx] = into
		}
		for target, reactors := range bucket {
			key := t.internLocked(target)
			dst := into[key]
			if dst == nil {
				dst = make(map[string]float64, len(reactors))
				into[key] = dst
				t.total++
			}
			for pk, w := range reactors {
				if pk := t.internLocked(pk); w > dst[pk] {
					dst[pk] = w
				}
			}
		}
	}
	for idx, s := range in.Covered {
		if idx < oldest {
			continue
		}
		if s > t.covered[idx] {
			t.covered[idx] = s
		}
	}
}

// popularTallyPath is where the snapshot lives, beside the other caches.
func popularTallyPath() string {
	return config.PopularTallyCachePath
}

// ---------------------------------------------------------------------------
// Ingest
// ---------------------------------------------------------------------------

// ingestPopularEngagement keeps a live subscription to the seed relays for
// engagement kinds and feeds everything it sees to the tally.
//
// Loop shape is the inbox subscription's (import.go): SubscribeMany's channel
// closes on context cancel or when every relay sends CLOSED, so a close is
// treated as reconnect-with-capped-backoff rather than as terminal.
func ingestPopularEngagement(ctx context.Context) {
	if !config.PopularTallyEnabled {
		log.Println("📊 popular tally disabled")
		return
	}
	if pool == nil {
		return
	}
	relays := config.ImportSeedRelays
	if len(relays) == 0 {
		log.Println("📊 popular tally: no seed relays configured")
		return
	}

	popularTally.load(popularTallyPath(), time.Now())
	if targets, buckets := popularTally.stats(time.Now()); targets > 0 {
		log.Printf("📊 popular tally restored: %d targets across %d hours", targets, buckets)
	}

	go persistPopularTally(ctx)

	log.Println("📊 subscribing to engagement (kinds 7/6/9735) on", len(relays), "relays")
	backoff := time.Second
	var watermark int64
	for ctx.Err() == nil {
		since := ingestSince(watermark, time.Now())
		filter := nostr.Filter{Kinds: []int{7, 6, 9735}, Since: &since}

		sawEvent := false
		mark := time.NewTicker(popularCoverageMarkEvery)
		done := make(chan struct{})
		go func() {
			// Liveness marks while the subscription is quiet. Without this a
			// healthy but idle socket would accrue no coverage and Popular
			// would keep paying for a network fetch it does not need.
			for {
				select {
				case <-done:
					return
				case <-ctx.Done():
					return
				case now := <-mark.C:
					popularTally.markAlive(now)
				}
			}
		}()

		popularTally.markAlive(time.Now())
		for ev := range pool.SubscribeMany(ctx, relays, filter) {
			sawEvent = true
			now := time.Now()
			popularTally.markAlive(now)
			popularTally.add(ev.Event, now)
			if at := int64(ev.CreatedAt); at > watermark && at <= now.Add(popularMaxClockSkew).Unix() {
				watermark = at
			}
		}
		mark.Stop()
		close(done)

		if ctx.Err() != nil {
			break
		}
		if sawEvent {
			backoff = time.Second
		}
		log.Println("📊 popular tally subscription closed, reconnecting in", backoff)
		select {
		case <-ctx.Done():
		case <-time.After(backoff):
		}
		if backoff < 60*time.Second {
			backoff *= 2
		}
	}
	// Best effort on the way out; the periodic save covers a hard kill.
	_ = popularTally.save(popularTallyPath(), time.Now())
}

// ingestSince is where a subscription resumes from.
//
// The first pass asks for the whole window, and the relays' replay of it is
// what makes a cold start useful immediately (measured: 24 buckets filled in
// 90 seconds). Every reconnect after that resumes from the newest event
// already seen — without the watermark a flaky connection would re-download
// the same day of history on every retry, which on cellular is the sort of
// thing that gets an app uninstalled.
func ingestSince(watermark int64, now time.Time) nostr.Timestamp {
	windowStart := now.Add(-popularWindow).Unix()
	if watermark > windowStart {
		return nostr.Timestamp(watermark)
	}
	return nostr.Timestamp(windowStart)
}

// persistPopularTally snapshots the tally every 5 minutes. Frequent enough
// that a crash loses minutes rather than a day, cheap because only multi-
// reactor targets are written.
func persistPopularTally(ctx context.Context) {
	ticker := time.NewTicker(5 * time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-ticker.C:
			if err := popularTally.save(popularTallyPath(), now); err != nil {
				log.Printf("popular: tally snapshot failed: %v", err)
			}
		}
	}
}
