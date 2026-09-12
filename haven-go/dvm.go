package main

import (
	"context"
	"encoding/hex"
	"fmt"
	"log"
	"math"
	"sort"
	"sync"
	"time"

	"github.com/fiatjaf/eventstore"
	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/pkg/wot"
)

// PopularNote holds a note with its computed popularity score.
type PopularNote struct {
	ID        string     `json:"id"`
	PubKey    string     `json:"pubkey"`
	Content   string     `json:"content"`
	CreatedAt int64      `json:"created_at"`
	Tags      [][]string `json:"tags"`
	Kind      int        `json:"kind"`
	Score     float64    `json:"score"`
}

var (
	popularCache       []PopularNote
	popularCacheExpiry time.Time
	popularCacheMu     sync.Mutex

	// A result that cost a network round trip is held longer than one read
	// out of the local tally: the fetch is what we are trying to avoid, and
	// the local read is cheap enough to redo for fresher ranking.
	popularCacheTTL      = 5 * time.Minute
	popularLocalCacheTTL = 60 * time.Second
)

const (
	// A note must have engagement from this many *different* trusted pubkeys
	// (not counting its own author) before it can appear in the Popular feed.
	//
	// It was 5 while any account's reaction counted. Now that only accounts
	// inside the owner's web of trust do, the pool is far smaller — measured
	// on the shipped seed relays, 7.7% of the accounts reacting to anything in
	// a day were inside the graph — and the bar is harder to clear at the same
	// number. Five strangers are trivial to manufacture; three people your
	// follows follow are not.
	minTrustedReactors = 3

	// Most notes any one author may contribute to a single Popular result set.
	maxNotesPerAuthor = 3
)

// reactionTargetID returns the note a kind-7/6/9735 event refers to.
//
// NIP-25: "the last e tag MUST be the id of the note being reacted to". An
// earlier version took the *first* e-tag, which on a reaction to a reply is
// the thread root — so credit landed on the top of the thread instead of the
// note that actually earned it. Reposts and zap receipts normally carry a
// single e-tag, for which first and last are the same.
func reactionTargetID(tags nostr.Tags) string {
	target := ""
	for _, tag := range tags {
		if len(tag) >= 2 && tag[0] == "e" {
			target = tag[1]
		}
	}
	return target
}

// addEngagement records one reaction/repost/zap against the note it refers to.
//
// A reactor contributes a single entry per note, at the strongest thing they
// did — that is what makes the feed cost distinct identities to game rather
// than distinct clicks. Kinds outside the scored set are ignored rather than
// stored at weight zero: a phantom entry would still count towards the
// distinct-reactor floor while adding no score.
func addEngagement(tally map[string]map[string]float64, ev *nostr.Event) {
	if ev == nil {
		return
	}
	weight := engagementWeight(ev.Kind)
	if weight == 0 {
		return
	}

	targetID := reactionTargetID(ev.Tags)
	if targetID == "" {
		return
	}

	reactors := tally[targetID]
	if reactors == nil {
		reactors = make(map[string]float64)
		tally[targetID] = reactors
	}
	if weight > reactors[ev.PubKey] {
		reactors[ev.PubKey] = weight
	}
}

// scoredTarget is a note id with the summed weight of its distinct reactors.
type scoredTarget struct {
	id    string
	score float64
}

// rankTargets drops targets with fewer than minDistinct reactors and returns
// the rest sorted by score, highest first. Ties break on id so the ordering is
// total — Go map iteration is randomised, and without the tie-break two runs
// over the same data could disagree about which note leads.
func rankTargets(tally map[string]map[string]float64, minDistinct int) []scoredTarget {
	ranked := make([]scoredTarget, 0, len(tally))
	for id, reactors := range tally {
		if len(reactors) < minDistinct {
			continue
		}
		var total float64
		for _, w := range reactors {
			total += w
		}
		ranked = append(ranked, scoredTarget{id, total})
	}
	sort.Slice(ranked, func(i, j int) bool {
		if ranked[i].score != ranked[j].score {
			return ranked[i].score > ranked[j].score
		}
		return ranked[i].id < ranked[j].id
	})
	return ranked
}

// scoreExcludingAuthor sums a note's reactor weights ignoring the note's own
// author, and reports how many distinct reactors are left. Self-engagement is
// not evidence that anyone else cared.
func scoreExcludingAuthor(reactors map[string]float64, author string) (float64, int) {
	var total float64
	distinct := 0
	for pk, w := range reactors {
		if pk == author {
			continue
		}
		total += w
		distinct++
	}
	return total, distinct
}

// capPerAuthor keeps at most `limit` notes per pubkey, preserving input order
// (callers sort by score first, so each author keeps their highest-scoring
// notes).
func capPerAuthor(notes []PopularNote, limit int) []PopularNote {
	if limit <= 0 {
		return notes
	}
	counts := make(map[string]int, len(notes))
	kept := make([]PopularNote, 0, len(notes))
	for _, n := range notes {
		if counts[n.PubKey] >= limit {
			continue
		}
		counts[n.PubKey]++
		kept = append(kept, n)
	}
	return kept
}

// fetchEngagementInto pulls the last 24h of engagement events from the seed
// relays and folds them into an existing tally. This is the original
// snapshot path, kept as the backfill for a device whose passive tally has not
// been running long enough to answer on its own — a phone the OS suspends
// between glances. Folding into the same map rather than replacing it means a
// backfilled read is still strictly better informed than today's: it has the
// network's snapshot *plus* whatever this device watched arrive live.
// A variable, not a plain function, so a test can observe whether the read
// path reached for the network at all — the assertion "Popular was answered
// locally" is otherwise indistinguishable from "the fetch failed and its error
// was swallowed", which is exactly how the first version of that test passed
// against code that always fetched.
var fetchEngagementInto = func(ctx context.Context, tally map[string]map[string]float64) error {
	if pool == nil {
		return fmt.Errorf("relay pool not initialized")
	}
	relays := config.ImportSeedRelays
	if len(relays) == 0 {
		return fmt.Errorf("no seed relays configured")
	}

	since := nostr.Timestamp(time.Now().Add(-24 * time.Hour).Unix())
	engagementFilter := nostr.Filter{
		Kinds: []int{7, 6, 9735},
		Since: &since,
		Limit: 5000,
	}

	fetchCtx, fetchCancel := context.WithTimeout(ctx, 15*time.Second)
	defer fetchCancel()

	seenIDs := make(map[string]struct{})
	for ev := range pool.FetchMany(fetchCtx, relays, engagementFilter) {
		if _, seen := seenIDs[ev.ID]; seen {
			continue
		}
		seenIDs[ev.ID] = struct{}{}
		addEngagement(tally, ev.Event)
	}
	return nil
}

// resolveNoteBodies finds the note behind each winning id, local stores first.
// The tally only ever holds target ids; on a device that has been running, the
// notes people are reacting to are usually already in the feed cache, so the
// common case costs no network at all. Only the ids nothing local knows about
// are fetched, and there are at most a hundred of them.
func resolveNoteBodies(ctx context.Context, ids []string) []*nostr.Event {
	found := make(map[string]*nostr.Event, len(ids))

	for _, db := range []DBBackend{feedDB, outboxDB, inboxDB, privateDB} {
		if db == nil || len(found) == len(ids) {
			continue
		}
		missing := missingIDs(ids, found)
		if len(missing) == 0 {
			break
		}
		wdb := eventstore.RelayWrapper{Store: db}
		evs, err := wdb.QuerySync(ctx, nostr.Filter{Kinds: []int{1, 30023}, IDs: missing})
		if err != nil {
			continue
		}
		for _, ev := range evs {
			found[ev.ID] = ev
		}
	}

	if missing := missingIDs(ids, found); len(missing) > 0 && pool != nil {
		relays := config.ImportSeedRelays
		if len(relays) > 0 {
			noteCtx, noteCancel := context.WithTimeout(ctx, 15*time.Second)
			defer noteCancel()
			for ev := range pool.FetchMany(noteCtx, relays, nostr.Filter{Kinds: []int{1, 30023}, IDs: missing}) {
				if _, have := found[ev.ID]; !have {
					found[ev.ID] = ev.Event
				}
			}
		}
	}

	out := make([]*nostr.Event, 0, len(found))
	for _, ev := range found {
		out = append(out, ev)
	}
	return out
}

// missingIDs returns the ids not yet resolved, preserving order.
func missingIDs(ids []string, found map[string]*nostr.Event) []string {
	missing := make([]string, 0, len(ids))
	for _, id := range ids {
		if _, ok := found[id]; !ok {
			missing = append(missing, id)
		}
	}
	return missing
}

// scoreNotes applies the author-exclusion, floor, decay and per-author cap to
// resolved notes. Split out of computePopularNotes so a test can drive the
// exact scoring the app sees without a relay pool.
func scoreNotes(events []*nostr.Event, tally map[string]map[string]float64, floor int, now time.Time) []PopularNote {
	var results []PopularNote
	seen := make(map[string]struct{}, len(events))
	for _, ev := range events {
		if _, dup := seen[ev.ID]; dup {
			continue
		}
		seen[ev.ID] = struct{}{}

		// The author's own engagement with their own note does not count, and
		// dropping it can put the note back under the floor — an author plus
		// four friends is not the same signal as five independent people.
		rawScore, distinct := scoreExcludingAuthor(tally[ev.ID], ev.PubKey)
		if distinct < floor {
			continue
		}

		// Time decay: notes older than 12h start losing score
		ageHours := now.Sub(ev.CreatedAt.Time()).Hours()
		decay := math.Max(0.2, 1.0-math.Max(0, ageHours-12)*0.05)

		tags := make([][]string, len(ev.Tags))
		for i, tag := range ev.Tags {
			tags[i] = []string(tag)
		}

		results = append(results, PopularNote{
			ID:        ev.ID,
			PubKey:    ev.PubKey,
			Content:   ev.Content,
			CreatedAt: int64(ev.CreatedAt),
			Tags:      tags,
			Kind:      ev.Kind,
			Score:     rawScore * decay,
		})
	}

	sort.Slice(results, func(i, j int) bool {
		if results[i].Score != results[j].Score {
			return results[i].Score > results[j].Score
		}
		return results[i].ID < results[j].ID
	})

	// No single author may own the feed. Even a legitimately viral account
	// posting ten times in a day should not push everyone else off the
	// screen, and it denies a spammer who does clear the floor the ability
	// to fill it. Applied after sorting so each author keeps their best.
	return capPerAuthor(results, maxNotesPerAuthor)
}

// trustGraph returns the owner's web of trust when it is usable.
//
// Why the gate is on the reactors rather than the authors: measured against
// the shipped seed relays on 2026-09-09, 95 of the top 100 Popular notes were
// one campaign — 13 accounts posting "In this week's issue", boosted by 6,467
// accounts of which **two** were inside the owner's graph, while 73 of the 75
// accounts boosting the five genuine notes were. Gating on the author would
// have caught half of it at best: 6 of those 13 authors are already inside the
// graph, because somebody the owner follows follows them. What a manufactured
// audience cannot fake is being known to the people you actually know.
func trustGraph(ctx context.Context) (wot.Model, bool) {
	model := wot.GetInstance()
	if model == nil || !trustGraphUsable(ctx, model) {
		return nil, false
	}
	return model, true
}

// filterToTrusted drops engagement from accounts outside the graph, and with
// it any note left with no trusted engagement at all.
func filterToTrusted(ctx context.Context, model wot.Model, tally map[string]map[string]float64) map[string]map[string]float64 {
	trusted := make(map[string]map[string]float64, len(tally))
	for target, reactors := range tally {
		kept := make(map[string]float64, len(reactors))
		for pk, w := range reactors {
			if model.Has(ctx, pk) {
				kept[pk] = w
			}
		}
		if len(kept) > 0 {
			trusted[target] = kept
		}
	}
	return trusted
}

// trustGraphUsable reports whether the model can actually answer questions.
//
// Has() returns false for everything both when a pubkey is untrusted and when
// the graph has not been built yet, so a size check is needed to tell a cold
// start from a world of strangers. A model that answers true for a pubkey
// nobody has ever seen is one with the graph disabled (WOT_DEPTH=0), which is
// a deliberate configuration: the gate is then a no-op rather than a wall.
func trustGraphUsable(ctx context.Context, model wot.Model) bool {
	if sized, ok := model.(interface{ Size() int }); ok && sized.Size() > 0 {
		return true
	}
	var nobody [32]byte
	nobody[0] = 0x0f
	nobody[31] = 0xf0
	return model.Has(ctx, hex.EncodeToString(nobody[:]))
}

// computePopularNotes answers the Popular feed.
//
// It reads the rolling tally the always-on subscription has been filling
// (popular_tally.go) and only reaches for the network when that tally has not
// been running long enough to be trusted on its own. The scoring below is the
// same code the old snapshot-only path used; what changed is where the
// engagement data comes from.
func computePopularNotes(ctx context.Context) ([]PopularNote, error) {
	now := time.Now()

	popularCacheMu.Lock()
	if now.Before(popularCacheExpiry) && len(popularCache) > 0 {
		cached := make([]PopularNote, len(popularCache))
		copy(cached, popularCache)
		popularCacheMu.Unlock()
		return cached, nil
	}
	popularCacheMu.Unlock()

	// Fails closed, and before anything expensive. An unusable graph means the
	// only feed we could build is the open firehose, which is how the spam got
	// in — the Global feed makes the same call, and its comment records that
	// firehose as measuring two thirds spam. The relay writes a graph shortly
	// after first launch.
	model, gated := trustGraph(ctx)
	if !gated {
		log.Println("popular: trust graph not ready, withholding the feed")
		return []PopularNote{}, nil
	}

	tally := popularTally.snapshot(now)
	coverage := popularTally.coverage(now)

	// Below the coverage floor the tally is a partial view — a phone that was
	// awake for ten minutes knows about ten minutes of engagement. Backfill.
	local := coverage >= popularTallyMinCoverage
	if !local {
		if err := fetchEngagementInto(ctx, tally); err != nil && len(tally) == 0 {
			return nil, err
		}
	}

	if len(tally) == 0 {
		return []PopularNote{}, nil
	}

	// Only engagement from inside the owner's web of trust counts. Without
	// this the feed is whatever the largest bot pool decided to promote.
	raw := len(tally)
	tally = filterToTrusted(ctx, model, tally)
	floor := minTrustedReactors

	if len(tally) == 0 {
		return []PopularNote{}, nil
	}

	ranked := rankTargets(tally, floor)
	log.Printf("popular: %d candidate notes (%d before the trust gate), %d eligible at %d trusted reactors (coverage %.0f%%, %s)",
		len(tally), raw, len(ranked), floor, coverage*100,
		map[bool]string{true: "local", false: "backfilled"}[local])
	if len(ranked) == 0 {
		return []PopularNote{}, nil
	}
	if len(ranked) > 100 {
		ranked = ranked[:100]
	}

	topIDs := make([]string, len(ranked))
	for i, r := range ranked {
		topIDs[i] = r.id
	}

	results := scoreNotes(resolveNoteBodies(ctx, topIDs), tally, floor, now)

	ttl := popularCacheTTL
	if local {
		ttl = popularLocalCacheTTL
	}
	popularCacheMu.Lock()
	popularCache = make([]PopularNote, len(results))
	copy(popularCache, results)
	popularCacheExpiry = now.Add(ttl)
	popularCacheMu.Unlock()

	return results, nil
}
