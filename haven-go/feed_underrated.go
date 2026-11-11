package main

// Underrated feed (local DVM): Popular turned over. Popular puts the most
// engaged notes first; Underrated looks for the note that did well *for its
// author*, among people you do not follow yet whom your follows follow (one
// step out; your own follows are left out entirely): people who post less and are known to fewer people in your web,
// whose likes, reposts and zaps are measured against what that person usually
// gets, with extra weight for notes bridged in from another network (NIP-48
// "proxy" tag), whose authors start with no Nostr audience at all.
//
// It reads the same engagement Popular does (the passive tally, backfilled
// when thin) and keeps Popular's defences: only reactors inside your web of
// trust count, the author's own engagement does not, the bar is the same
// three trusted people, and the feed is withheld while the trust graph is
// not built.

import (
	"context"
	"encoding/json"
	"log"
	"math"
	"sort"
	"sync"
	"time"

	"github.com/fiatjaf/eventstore"
	"github.com/nbd-wtf/go-nostr"
)

const (
	// Distinct trusted reactors (author excluded) a note needs: Popular's
	// bar. Two was tried and is what a manufactured campaign already clears
	// (dvm.go trustGraph: 6,467 boosters, two inside the graph), and the
	// formula below gives strangers its best weights (Tron, #1830).
	underratedMinReactors = minTrustedReactors
	// Candidates whose bodies are looked up, most engaged first.
	// Most of the engagement your web sees is on your own follows' notes,
	// which Underrated leaves out, so it looks further down than Popular.
	underratedMaxCandidates = 600
	// Notes one Underrated result lists, and the most per author.
	underratedMaxNotes       = 100
	underratedMaxPerAuthor   = 2
	underratedBridgeBoost    = 1.5
	underratedPostCountLimit = 200
	// Posts assumed for an author the local stores know nothing about (not
	// a follow, so not in feedDB): no "posts less" boost for an unknown, or
	// a stranger posting a thousand times a day would count as one post.
	underratedUnknownPosts = 8
)

var (
	underratedCache       []PopularNote
	underratedCacheExpiry time.Time
	underratedCacheMu     sync.Mutex
)

// reachModel is the part of the web of trust Underrated reads: how many of
// your follows follow someone (pkg/wot SimpleInMemory).
type reachModel interface {
	Reach(pubkey string) (vouches int, follow bool, known bool)
}

// isBridged reports a NIP-48 proxy tag: the note was brought over from
// another protocol (ActivityPub, AT Protocol, RSS, ...).
func isBridged(tags nostr.Tags) bool {
	for _, tag := range tags {
		if len(tag) >= 3 && tag[0] == "proxy" && tag[1] != "" {
			return true
		}
	}
	return false
}

// underratedInputs is everything the scoring needs besides the notes and the
// tally, so a test can drive it without stores or a graph.
type underratedInputs struct {
	// posts is how many posts each author made in the window, as far as the
	// local stores know (0 or missing = unknown: underratedUnknownPosts).
	posts map[string]int
	// oneStepOut returns how many of your follows follow the author, and
	// false for anyone Underrated leaves out: people you follow, and people
	// none of your follows follow. nil leaves everyone out (fails closed).
	oneStepOut func(pubkey string) (int, bool)
	// drops, when set, counts the notes left out and why (the log line).
	drops *underratedDrops
}

// underratedDrops is why resolved notes did not make the list. Counting
// only: nothing here changes what qualifies or how it ranks.
type underratedDrops struct {
	notOneStepOut int // a follow, someone no follow follows, or a web with no vouch layer
	belowBar      int // fewer than underratedMinReactors trusted people (author excluded)
	perAuthorCap  int // past underratedMaxPerAuthor for its author
	overLimit     int // past underratedMaxNotes
}

// Why an Underrated answer is empty, for the apps (ComputeUnderratedNotesC
// answers {"reason": ...} instead of an empty list).
const (
	// The trust graph is not built yet: the feed is withheld (the apps
	// already say the web is being built and wait for it).
	underratedWebNotReady = "web_not_ready"
	// The web is follows only (depth below 3, or no vouch layer): nobody
	// can be one step out until the wider network is built.
	underratedWebIncomplete = "web_incomplete"
	// The web is whole and still nothing cleared the bar.
	underratedNothingQualified = "nothing_qualified"
)

// webShaper is the part of the web of trust that says how far it reaches
// (pkg/wot SimpleInMemory.WebShape).
type webShaper interface {
	WebShape() (depth, follows, vouched int)
}

// webShapeOf reads how far model reaches. A model that cannot say counts as
// follows only: oneStepOutFrom cannot name anyone in it either.
func webShapeOf(model any) (depth, follows, vouched int) {
	if ws, ok := model.(webShaper); ok {
		return ws.WebShape()
	}
	return 0, 0, 0
}

// underratedWebComplete: a web Underrated can find anyone in. Its people
// are the second layer, which only a depth-3 build with vouch counts has.
func underratedWebComplete(depth, vouched int) bool {
	return depth >= 3 && vouched > 0
}

// underratedEmptyJSON is the bridge's empty answer: {"reason": reason}.
func underratedEmptyJSON(reason string) string {
	b, _ := json.Marshal(map[string]string{"reason": reason})
	return string(b)
}

// underratedEmptyReason says why an empty answer is empty.
func underratedEmptyReason(ready bool, depth, vouched int) string {
	switch {
	case !ready:
		return underratedWebNotReady
	case !underratedWebComplete(depth, vouched):
		return underratedWebIncomplete
	default:
		return underratedNothingQualified
	}
}

// oneStepOutFrom reads the web of trust for Underrated: someone you do not
// follow whom at least one of your follows does (the second layer). A graph
// without vouch counts (depth 2, or not built) cannot tell, so it names
// nobody (Logen 2026-11-06: Underrated showed mostly his own follows).
func oneStepOutFrom(rm reachModel) func(string) (int, bool) {
	return func(pk string) (int, bool) {
		vouches, follow, known := rm.Reach(pk)
		if follow || !known || vouches <= 0 {
			return 0, false
		}
		return vouches, true
	}
}

// scoreUnderrated ranks resolved notes. Per note, with raw the summed weight
// of its trusted reactors (author excluded):
//
//	base   = log2(1 + raw)                      engagement counts, damped
//	lift   = (raw + 1) / (usual + 1)            against the author's own usual
//	posts  = 1 / (1 + log2(posts))              fewer posts, more weight
//	         (an author the local stores don't know counts as 8)
//	reach  = 1 / (1 + log2(1 + vouches))        known to fewer of your follows
//	bridge = 1.5 for a NIP-48 bridged note
//	decay  = Popular's: full for 12h, then down to 0.2
//
// usual is the author's engagement in the window over their posts in it:
// a note that drew what the author's other posts did scores lift 1, a quiet
// author's one good note far more.
func scoreUnderrated(events []*nostr.Event, tally map[string]map[string]float64, in underratedInputs, now time.Time) []PopularNote {
	type cand struct {
		ev  *nostr.Event
		raw float64
	}
	var cands []cand
	authorTotal := map[string]float64{}
	authorNotes := map[string]int{}
	seen := make(map[string]struct{}, len(events))
	for _, ev := range events {
		if ev == nil {
			continue
		}
		if _, dup := seen[ev.ID]; dup {
			continue
		}
		seen[ev.ID] = struct{}{}
		if in.oneStepOut == nil {
			if in.drops != nil {
				in.drops.notOneStepOut++
			}
			continue
		}
		if _, ok := in.oneStepOut(ev.PubKey); !ok {
			if in.drops != nil {
				in.drops.notOneStepOut++
			}
			continue
		}
		raw, distinct := scoreExcludingAuthor(tally[ev.ID], ev.PubKey)
		if distinct < underratedMinReactors {
			if in.drops != nil {
				in.drops.belowBar++
			}
			continue
		}
		cands = append(cands, cand{ev, raw})
		authorTotal[ev.PubKey] += raw
		authorNotes[ev.PubKey]++
	}

	results := make([]PopularNote, 0, len(cands))
	for _, c := range cands {
		pk := c.ev.PubKey
		known := in.posts[pk]
		posts := max(known, authorNotes[pk], 1)
		usual := authorTotal[pk] / float64(posts)
		if known <= 0 {
			// Unknown: the usual is what we saw, and no boost for posting less.
			posts = max(authorNotes[pk], underratedUnknownPosts)
		}
		score := math.Log2(1+c.raw) *
			((c.raw + 1) / (usual + 1)) *
			(1 / (1 + math.Log2(float64(posts))))
		if vouches, ok := in.oneStepOut(pk); ok {
			score *= 1 / (1 + math.Log2(1+float64(max(vouches, 0))))
		}
		if isBridged(c.ev.Tags) {
			score *= underratedBridgeBoost
		}
		ageHours := now.Sub(c.ev.CreatedAt.Time()).Hours()
		score *= math.Max(0.2, 1.0-math.Max(0, ageHours-12)*0.05)
		results = append(results, toPopularNote(c.ev, score))
	}
	sort.Slice(results, func(i, j int) bool {
		if results[i].Score != results[j].Score {
			return results[i].Score > results[j].Score
		}
		return results[i].ID < results[j].ID
	})
	sorted := len(results)
	results = capPerAuthor(results, underratedMaxPerAuthor)
	if in.drops != nil {
		in.drops.perAuthorCap += sorted - len(results)
	}
	if len(results) > underratedMaxNotes {
		if in.drops != nil {
			in.drops.overLimit += len(results) - underratedMaxNotes
		}
		results = results[:underratedMaxNotes]
	}
	return results
}

// underratedCandidates is the ids worth resolving: at the reactor bar
// (author not yet excluded: the author is unknown until the body is), most
// engaged first, capped.
func underratedCandidates(tally map[string]map[string]float64) []string {
	ranked := rankTargets(tally, underratedMinReactors)
	if len(ranked) > underratedMaxCandidates {
		ranked = ranked[:underratedMaxCandidates]
	}
	ids := make([]string, len(ranked))
	for i, r := range ranked {
		ids[i] = r.id
	}
	return ids
}

// localPostCounts counts each author's posts in the window from the local
// stores (feedsync keeps the follows' notes in feedDB).
func localPostCounts(ctx context.Context, authors []string, since nostr.Timestamp) map[string]int {
	counts := make(map[string]int, len(authors))
	if feedDB == nil {
		return counts
	}
	wdb := eventstore.RelayWrapper{Store: feedDB}
	for _, pk := range authors {
		if ctx.Err() != nil {
			break
		}
		evs, err := wdb.QuerySync(ctx, nostr.Filter{Kinds: catchUpKinds, Authors: []string{pk}, Since: &since, Limit: underratedPostCountLimit})
		if err == nil {
			counts[pk] = len(evs)
		}
	}
	return counts
}

// computeUnderratedNotes answers the Underrated feed, and when the answer is
// empty, why (underratedWebIncomplete and the rest; "" when it is not).
func computeUnderratedNotes(ctx context.Context) ([]PopularNote, string, error) {
	now := time.Now()
	underratedCacheMu.Lock()
	if now.Before(underratedCacheExpiry) && len(underratedCache) > 0 {
		cached := append([]PopularNote(nil), underratedCache...)
		underratedCacheMu.Unlock()
		return cached, "", nil
	}
	underratedCacheMu.Unlock()

	// Fails closed, as Popular does (computePopularNotes).
	model, gated := trustGraph(ctx)
	if !gated {
		log.Println("underrated: trust graph not ready, withholding the feed")
		return []PopularNote{}, underratedEmptyReason(false, 0, 0), nil
	}
	depth, follows, vouched := webShapeOf(model)
	emptyReason := func(results []PopularNote) string {
		if len(results) > 0 {
			return ""
		}
		return underratedEmptyReason(true, depth, vouched)
	}

	tally := popularTally.snapshot(now)
	local := popularTally.coverage(now) >= popularTallyMinCoverage
	if !local {
		if err := fetchEngagementInto(ctx, tally); err != nil && len(tally) == 0 {
			return nil, "", err
		}
	}
	tally = filterToTrusted(ctx, model, tally)
	ids := underratedCandidates(tally)
	if len(ids) == 0 {
		log.Printf("underrated: 0 candidates (depth=%d follows=%d vouched=%d)", depth, follows, vouched)
		return []PopularNote{}, emptyReason(nil), nil
	}
	events := resolveNoteBodies(ctx, ids)

	authors := make([]string, 0, len(events))
	seenAuthor := map[string]struct{}{}
	for _, ev := range events {
		if _, ok := seenAuthor[ev.PubKey]; !ok {
			seenAuthor[ev.PubKey] = struct{}{}
			authors = append(authors, ev.PubKey)
		}
	}
	var drops underratedDrops
	in := underratedInputs{posts: localPostCounts(ctx, authors, nostr.Timestamp(now.Add(-popularWindow).Unix())), drops: &drops}
	if rm, ok := model.(reachModel); ok {
		in.oneStepOut = oneStepOutFrom(rm)
	}
	results := scoreUnderrated(events, tally, in, now)
	log.Printf("underrated: %d candidates, %d resolved, %d ranked (%s) depth=%d follows=%d vouched=%d dropped: unresolved=%d not_one_step_out=%d below_bar=%d per_author_cap=%d over_limit=%d",
		len(ids), len(events), len(results), map[bool]string{true: "local", false: "backfilled"}[local],
		depth, follows, vouched,
		len(ids)-len(events), drops.notOneStepOut, drops.belowBar, drops.perAuthorCap, drops.overLimit)

	ttl := popularCacheTTL
	if local {
		ttl = popularLocalCacheTTL
	}
	underratedCacheMu.Lock()
	underratedCache = append([]PopularNote(nil), results...)
	underratedCacheExpiry = now.Add(ttl)
	underratedCacheMu.Unlock()
	return results, emptyReason(results), nil
}
