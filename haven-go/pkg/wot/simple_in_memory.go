package wot

import (
	"cmp"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"maps"
	"os"
	"path/filepath"
	"runtime/debug"
	"slices"
	"sync"
	"sync/atomic"
	"time"

	"github.com/nbd-wtf/go-nostr"
	"github.com/puzpuzpuz/xsync/v4"
)

const DefaultWotLevel = 3

type wotCache struct {
	Pubkeys   map[string]bool `json:"pubkeys"`
	Timestamp int64           `json:"timestamp"`
	// Depth the graph was built at. A cache from another depth is a different
	// graph: without this, changing the depth setting kept serving the old one
	// until the TTL ran out. Caches written before this field read as 0 and
	// are rebuilt once.
	Depth int `json:"depth"`
	// Version of how the graph was built. Bump it when a fix changes the
	// result, so graphs built by the broken code are rebuilt instead of being
	// served for the rest of their TTL.
	Version int `json:"version"`
	// Follows are the owners' own follows: the web's first layer. Everyone
	// else in Pubkeys (not an owner) is the second layer, the people the
	// apps call "your web".
	Follows []string `json:"follows,omitempty"`
	// Vouches counts, for each second-layer person, how many of the owners'
	// follows follow them. Depth 3 only: depth 2 has no second layer.
	Vouches map[string]int `json:"vouches,omitempty"`
}

// wotLinks is who follows whom inside the web, saved next to the cache as
// linksFile. The depth-3 pass downloads every follow's list anyway; keeping
// the "who" and not just the count lets the apps draw the lines from you,
// through your follows, to anyone in the web the moment they tap them,
// instead of asking public relays for the same lists again. It is its own
// file so the apps' frequent wot_cache.json reloads stay small.
type wotLinks struct {
	Timestamp int64 `json:"timestamp"`
	// Follows are the owners' follows, sorted: the same list as wotCache's.
	Follows []string `json:"follows"`
	// Links names, for everyone in the web but the owners, which follows
	// follow them, as sorted indexes into Follows. Only as complete as the
	// lists the seed relays returned.
	Links map[string][]int `json:"links"`
}

const linksFile = "wot_links.json"

// wotCacheVersion 2: the depth-3 pass no longer drops every contact list a
// batch had collected when one seed relay was slow to send EOSE.
// wotCacheVersion 3: an owner who follows nobody is no longer seeded from a
// starter pack, so graphs built from those seeds are thrown away.
// wotCacheVersion 4: an owner with fewer follows than the bar gets their
// follows' follows (newAccountWeb), so their thin graphs are rebuilt.
const wotCacheVersion = 4

// listBatchSize is how many follows' lists one request asks for. Seed relays
// quietly answer oversized author filters with little or nothing: measured
// against a real 1,018-follow account, 1,000 per request got 383 lists back
// across the seed set and 250 got 495 (relay.btcforplebs.com went from 3 to
// 190, nostr-pub.wellorder.net from 6 to 120). 100 got no more than 250.
const listBatchSize = 250

type SimpleInMemory struct {
	pubkeys atomic.Pointer[map[string]bool]
	// layers is the follows + vouches of the graph in pubkeys, saved with it.
	layers atomic.Pointer[layers]
	// webs is each account's own web (accounts.go), built beside the pooled
	// graph in pubkeys.
	webs atomic.Pointer[accountWebs]

	// Dependencies for Refresh
	Pool               *nostr.SimplePool
	WhitelistedPubKeys map[string]struct{}

	SeedRelays      []string
	WotDepth        int
	MinFollowers    int
	WotFetchTimeout int
	CachePath       string
	CacheTTLMinutes int

	// LocalFollowLists returns the owners' follow lists as stored on this
	// relay. The app publishes an unfollow here first; a rebuild that asked
	// only the seed relays could get the list from before it and keep
	// everyone the unfollowed account brought in. Nil asks only the seeds.
	LocalFollowLists func() []*nostr.Event

	// ReachFor returns one account's own Follow Distance, and false when the
	// account has none of its own: it then uses WotDepth and MinFollowers.
	// Nil means no account has its own.
	ReachFor func(owner string) (AccountReach, bool)

	// BlockedBy reports whether the account owner has blocked pubkey. A
	// blocked follow vouches for nobody in that account's web. Nil: no blocks.
	BlockedBy func(owner, pubkey string) bool
	// accountsMu serializes the writers of webs (a build and RetallyAccounts).
	accountsMu sync.Mutex

	// builtAt is when the graph in pubkeys started building (unix seconds),
	// or the saved cache's time. A follow list newer than this is not in it.
	builtAt atomic.Int64
}

type layers struct {
	follows []string
	vouches map[string]int
}

func NewSimpleInMemory(pool *nostr.SimplePool, whitelistedPubKeys map[string]struct{}, seedRelays []string, wotDepth int, minFollowers int, wotFetchTimeout int, cachePath string, cacheTTLMinutes int) *SimpleInMemory {
	return &SimpleInMemory{
		Pool:               pool,
		WhitelistedPubKeys: whitelistedPubKeys,
		SeedRelays:         seedRelays,
		WotDepth:           wotDepth,
		MinFollowers:       minFollowers,
		WotFetchTimeout:    wotFetchTimeout,
		CachePath:          cachePath,
		CacheTTLMinutes:    cacheTTLMinutes,
	}
}

// Size reports how many pubkeys the graph currently holds.
//
// Has() alone cannot tell "this pubkey is untrusted" apart from "the graph has
// not been built yet" — both answer false. Anything that fails closed on an
// untrusted key therefore needs to know whether there is a graph at all, or a
// cold start looks exactly like a world full of strangers.
func (wt *SimpleInMemory) Size() int {
	m := wt.pubkeys.Load()
	if m == nil {
		return 0
	}
	return len(*m)
}

// NamesOnlyOwners reports whether a built graph holds nobody but the
// whitelisted owners: the owner follows no one yet. Depths 0 and 1 never hold
// anyone else, so they never count as waiting for follows.
// hasPeople reports whether graph names anyone besides the owners.
func hasPeople(graph map[string]bool, owners map[string]struct{}) bool {
	for pk := range graph {
		if _, owner := owners[pk]; !owner {
			return true
		}
	}
	return false
}

func (wt *SimpleInMemory) NamesOnlyOwners() bool {
	if wt.WotDepth < 2 {
		return false
	}
	m := wt.pubkeys.Load()
	if m == nil {
		return false
	}
	for pk := range *m {
		if _, owner := wt.WhitelistedPubKeys[pk]; !owner {
			return false
		}
	}
	return true
}

func (wt *SimpleInMemory) Has(_ context.Context, pubKey string) bool {
	if wt.WotDepth == 0 {
		return true
	}
	m := wt.pubkeys.Load()
	if m == nil {
		return false
	}
	return (*m)[pubKey]
}

// LoadFromCache attempts to load WoT from cache file if it exists and is fresh.
// ageMinutes is only meaningful when ok is true — callers use it to decide
// whether to also kick off an async Refresh even though the still-within-TTL
// cache is already serving Has() lookups (see PeriodicRefresh's doc comment
// for why a boot-time check is needed in addition to the in-process ticker).
func (wt *SimpleInMemory) LoadFromCache() (ok bool, ageMinutes int64) {
	if wt.CachePath == "" {
		return false, 0
	}

	data, err := os.ReadFile(wt.CachePath)
	if err != nil {
		return false, 0
	}

	var cache wotCache
	if err := json.Unmarshal(data, &cache); err != nil {
		slog.Warn("🚫 Failed to parse WoT cache", "error", err)
		return false, 0
	}

	if cache.Version != wotCacheVersion {
		slog.Info("🔁 WoT cache from an older build, rebuilding", "cached_version", cache.Version, "version", wotCacheVersion)
		return false, 0
	}
	if cache.Depth != wt.WotDepth {
		slog.Info("🔁 WoT cache built at another depth, rebuilding", "cached_depth", cache.Depth, "depth", wt.WotDepth)
		return false, 0
	}

	// Check if cache is still valid
	now := time.Now().Unix()
	age := (now - cache.Timestamp) / 60 // age in minutes
	if age > int64(wt.CacheTTLMinutes) {
		slog.Info("⏰ WoT cache expired", "age_minutes", age, "ttl_minutes", wt.CacheTTLMinutes)
		return false, 0
	}
	wt.pubkeys.Store(&cache.Pubkeys)
	wt.layers.Store(&layers{follows: cache.Follows, vouches: cache.Vouches})
	wt.builtAt.Store(cache.Timestamp)
	wt.loadAccountWebs()
	slog.Info("💾 Loaded WoT from cache", "pubkeys", len(cache.Pubkeys), "age_minutes", age)
	return true, age
}

// SaveCache writes the current WoT pubkeys to cache file
func (wt *SimpleInMemory) SaveCache() {
	if wt.CachePath == "" {
		return
	}

	m := wt.pubkeys.Load()
	if m == nil {
		return
	}

	stamp := wt.builtAt.Load()
	if stamp == 0 {
		stamp = time.Now().Unix()
	}
	cache := wotCache{
		Pubkeys:   *m,
		Timestamp: stamp,
		Depth:     wt.WotDepth,
		Version:   wotCacheVersion,
	}
	if l := wt.layers.Load(); l != nil {
		cache.Follows, cache.Vouches = l.follows, l.vouches
	}

	data, err := json.Marshal(cache)
	if err != nil {
		slog.Error("🚫 Failed to marshal WoT cache", "error", err)
		return
	}

	// Write a temp file and rename it over the cache, so a crash or a reader
	// mid-write never sees half a file.
	tmp := wt.CachePath + ".tmp"
	if err := os.WriteFile(tmp, data, 0644); err != nil {
		slog.Error("🚫 Failed to write WoT cache", "error", err)
		return
	}
	if err := os.Rename(tmp, wt.CachePath); err != nil {
		slog.Error("🚫 Failed to write WoT cache", "error", err)
		_ = os.Remove(tmp)
		return
	}

	slog.Debug("💾 Saved WoT cache", "pubkeys", len(*m))
}

func (wt *SimpleInMemory) linksPath() string {
	return filepath.Join(filepath.Dir(wt.CachePath), linksFile)
}

// MissingLinks reports a depth-3 graph whose links file is absent: a cache
// from before the file existed, or one whose links write failed. The graph
// itself is still good, so callers serve the cache and refresh in the
// background; until then the apps fall back to asking relays for the lines.
func (wt *SimpleInMemory) MissingLinks() bool {
	if wt.WotDepth < 3 || wt.CachePath == "" {
		return false
	}
	_, err := os.Stat(wt.linksPath())
	return err != nil
}

// saveLinks writes the links file, or removes it when links is nil (depths
// below 3 never see the follows' lists). The file is swapped in whole, so an
// app reading it never sees half a write.
func (wt *SimpleInMemory) saveLinks(follows []string, links map[string][]int) {
	if wt.CachePath == "" {
		return
	}
	path := wt.linksPath()
	if links == nil {
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			slog.Error("🚫 Failed to remove WoT links", "error", err)
		}
		return
	}
	data, err := json.Marshal(wotLinks{Timestamp: time.Now().Unix(), Follows: follows, Links: links})
	if err != nil {
		slog.Error("🚫 Failed to marshal WoT links", "error", err)
		return
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0644); err != nil {
		slog.Error("🚫 Failed to write WoT links", "error", err)
		return
	}
	if err := os.Rename(tmp, path); err != nil {
		slog.Error("🚫 Failed to save WoT links", "error", err)
	}
}

func (wt *SimpleInMemory) Init(ctx context.Context) {
	switch wt.WotDepth {
	case 0:
		slog.Info("Web of Trust Level 0 -> Disabled (Public Relay)")
	case 1:
		slog.Info("Web of Trust Level 1 -> Private Relay for the Owner")
	case 2:
		slog.Info("Web of Trust Level 2 -> Only pubkeys that the relay Owner is following directly can write to Inbox and Chat relays")
	case 3:
		slog.Info("Web of Trust Level 3 -> Connection of Connections (owner, follows, and their follows) with", "minFollowers", wt.MinFollowers)
	default:
		slog.Error("🚫 Web of Trust level not supported, must be between 0 and 3", "level", wt.WotDepth)
		slog.Info("Using default Web of Trust Level")
		wt.WotDepth = DefaultWotLevel
		slog.Info("Web of Trust Level 3 -> Connection of Connections (owner, follows, and their follows) with", "minFollowers", wt.MinFollowers)

	}
	// The first build must happen: wait out a rebuild still finishing
	// rather than skip it like Refresh would.
	for wt.WotDepth != 0 && !claimRefresh() {
		select {
		case <-ctx.Done():
			return
		case <-time.After(200 * time.Millisecond):
		}
	}
	if wt.WotDepth == 0 {
		// A public relay builds no web, so nothing else would clear the
		// files of an account removed since.
		wt.removeOtherAccountFiles(func(owner string) bool {
			_, own := wt.WhitelistedPubKeys[owner]
			return own
		})
		return
	}
	wt.build(ctx)
}

// Refresh rebuilds the graph unless a rebuild is already running.
func (wt *SimpleInMemory) Refresh(ctx context.Context) {
	if wt.WotDepth == 0 || !claimRefresh() {
		return
	}
	wt.build(ctx)
}

// BuiltAt is when the graph being served started building: a follow list
// published after it is not in it.
func (wt *SimpleInMemory) BuiltAt() time.Time {
	return time.Unix(wt.builtAt.Load(), 0)
}

// build is Refresh's work; the caller holds claimRefresh and build releases it.
func (wt *SimpleInMemory) build(ctx context.Context) {
	phase, size := "stopped", 0
	defer func() { releaseRefresh(phase, size) }()
	// Stamped with the start, not the save: a list published while this
	// build runs may have missed it, and must still look newer than the graph.
	started := time.Now().Unix()

	var eventsAnalysed atomic.Int64
	pubkeyFollowers := xsync.NewMap[string, *atomic.Int64]()
	oneHopNetwork := make(map[string]bool)
	newWot := make(map[string]bool)
	// The graph being replaced: anyone found who isn't on it is a newcomer.
	var previous map[string]bool
	if m := wt.pubkeys.Load(); m != nil {
		previous = *m
	}

	if wt.WotDepth >= 1 {
		for pubkey := range wt.WhitelistedPubKeys {
			newWot[pubkey] = true
		}
	}

	// Every depth persists its graph: the apps read wot_cache.json to filter
	// Global and Discovery, and depths 1 and 2 used to return without saving,
	// so on Android (depth 2 by default) that file never existed and both
	// feeds came up empty.
	if wt.WotDepth == 1 {
		wt.layers.Store(&layers{})
		wt.pubkeys.Store(&newWot)
		wt.builtAt.Store(started)
		wt.SaveCache()
		wt.saveLinks(nil, nil)
		wt.buildAccounts(ctx, started, nil, true, nil)
		phase, size = "saved", len(newWot)
		return
	}

	timeout := time.Duration(wt.WotFetchTimeout) * time.Second
	timeoutCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	ownerLists, ownersWhole := wt.fetchOwnerLists(timeoutCtx, &eventsAnalysed)
	for _, ev := range ownerLists {
		for contact := range ev.Tags.FindAll("p") {
			if len(contact) > 1 {
				followers, _ := pubkeyFollowers.LoadOrStore(contact[1], &atomic.Int64{})
				followers.Add(1)
				oneHopNetwork[contact[1]] = true
				if !newWot[contact[1]] {
					newWot[contact[1]] = true
					found(contact[1], previous)
				}
			}
		}
	}
	follows := slices.Sorted(maps.Keys(oneHopNetwork))

	// No follow list came back (offline, or every seed relay timed out), or
	// the relay is stopping: saving now would replace a real web with one
	// of just the owner. Keep the web we have; a first build still saves.
	if ctx.Err() != nil || (eventsAnalysed.Load() == 0 && hasPeople(previous, wt.WhitelistedPubKeys)) {
		slog.Warn("🚫 WoT rebuild got no follow lists; keeping the saved web")
		return
	}

	if wt.WotDepth == 2 {
		wt.layers.Store(&layers{follows: follows})
		slog.Info("🕸️ analysed Nostr events", "count", eventsAnalysed.Load())
		slog.Info("📈 direct followers in import relays", "🫂pubkeys", len(newWot), "🔗relays", len(wt.SeedRelays))
		wt.pubkeys.Store(&newWot)
		wt.builtAt.Store(started)
		wt.SaveCache()
		wt.saveLinks(nil, nil)
		wt.buildAccounts(ctx, started, ownerLists, ownersWhole, nil)
		phase, size = "saved", len(newWot)
		return
	}

	slog.Info("🕸️ analysing Nostr events", "count", eventsAnalysed.Load())

	keys := follows
	// Someone is in at MinFollowers; 0 and 1 both mean "any one follow".
	bar := max(int64(wt.MinFollowers), 1)
	followIndex := make(map[string]int, len(follows))
	for i, pk := range follows {
		followIndex[pk] = i
	}
	links := make(map[string][]int)
	// tally counts one follow's list: its people's follower counts, the
	// links file's "who follows them", and anyone clearing the bar, the
	// moment they do, so the apps can show the web filling in.
	tally := func(pk string, l followList) {
		from := followIndex[pk]
		for _, contact := range l.contacts {
			// One list's tags are counted together, so a repeated tag is
			// always the last index added.
			if lk := links[contact]; contact != pk && (len(lk) == 0 || lk[len(lk)-1] != from) {
				links[contact] = append(lk, from)
			}
			followers, _ := pubkeyFollowers.LoadOrStore(contact, &atomic.Int64{})
			if followers.Add(1) == bar && !newWot[contact] {
				found(contact, previous)
			}
		}
	}

	lists, fetched, incremental, freshComplete, changesComplete, since, fullAt := wt.fetchFollowLists(
		ctx, timeout, follows, followIndex, previous, ownersWhole, &eventsAnalysed, tally)

	// Same rule for the follows' lists: a pass that was cut short, or a full
	// pass that fetched none of them and would leave a smaller web, keeps the
	// web we have. (Follows with no lists anywhere still grow it, so they
	// save.) An incremental pass that fetched nothing found nothing changed:
	// the stored lists still count.
	if ctx.Err() != nil || (!incremental && len(keys) > 0 && fetched == 0 && len(newWot) < len(previous)) {
		slog.Warn("🚫 WoT rebuild got none of the follows' lists; keeping the saved web")
		return
	}

	slog.Info("📈 community size", "total_keys", pubkeyFollowers.Size())
	updateProgress(func(p *Progress) { p.Phase = "counting" })

	// Log Top N pubkeys by follower count for debugging purposes
	if slog.Default().Enabled(ctx, slog.LevelDebug) {
		type pubkeyCount struct {
			pubkey string
			count  int
		}
		const topN = 20

		h := make([]pubkeyCount, 0, topN+1)

		pubkeyFollowers.Range(func(pubkey string, followers *atomic.Int64) bool {
			count := int(followers.Load())
			if len(h) < topN {
				h = append(h, pubkeyCount{pubkey, count})
				if len(h) == topN {
					slices.SortFunc(h, func(a, b pubkeyCount) int {
						if n := cmp.Compare(a.count, b.count); n != 0 {
							return n
						}
						return cmp.Compare(b.pubkey, a.pubkey)
					})
				}
			} else if count > h[0].count || (count == h[0].count && pubkey < h[0].pubkey) {
				h[0] = pubkeyCount{pubkey, count}
				// Keep it sorted or use a proper heap. For a small value of N, keeping it sorted is simple.
				// Since we only replaced the smallest element, we can just "bubble up" that element to restore order.
				for i := 0; i < len(h)-1; i++ {
					if h[i].count > h[i+1].count || (h[i].count == h[i+1].count && h[i].pubkey < h[i+1].pubkey) {
						h[i], h[i+1] = h[i+1], h[i]
					} else {
						break
					}
				}
			}
			return true
		})

		slices.Reverse(h)

		slog.Debug(fmt.Sprintf("📊 WoT top %d pubkeys by follower count", topN))
		for _, c := range h {
			slog.Debug("👤", "pubkey", c.pubkey, "count", c.count)
		}
	}

	// Filter out pubkeys with less than minimum followers
	minimumFollowers := int64(wt.MinFollowers)
	vouches := make(map[string]int)
	pubkeyFollowers.Range(func(pubkey string, followers *atomic.Int64) bool {
		if followers.Load() >= minimumFollowers {
			if !newWot[pubkey] {
				vouches[pubkey] = int(followers.Load())
			}
			newWot[pubkey] = true
		}
		return true
	})

	slog.Info("🫥 pruned pubkeys without minimum common followers", "🚧minimum", minimumFollowers, "🫂kept", len(newWot), "🗑️eliminated", pubkeyFollowers.Size()-len(newWot))

	// Only a new account's small web is copied out; a full one never is.
	if len(follows) < int(minimumFollowers) {
		counts := make(map[string]int)
		pubkeyFollowers.Range(func(pubkey string, followers *atomic.Int64) bool {
			counts[pubkey] = int(followers.Load())
			return true
		})
		people := newAccountWeb(counts, newWot, len(follows), int(minimumFollowers))
		for _, pk := range people {
			vouches[pk] = counts[pk]
			newWot[pk] = true
			found(pk, previous)
		}
		slog.Info("🌱 new account: web widened to its follows' follows", "follows", len(follows), "🫂added", len(people))
	}

	for pk, from := range links {
		if _, owner := wt.WhitelistedPubKeys[pk]; owner || !newWot[pk] {
			delete(links, pk)
			continue
		}
		slices.Sort(from)
	}

	wt.layers.Store(&layers{follows: follows, vouches: vouches})
	wt.pubkeys.Store(&newWot)
	wt.builtAt.Store(started)
	wt.SaveCache()
	wt.saveLinks(follows, links)
	// The next rebuild asks for changes since this one only if every
	// changes fetch here was whole (no relay cut, or the cut ones answered
	// when asked again); a full pass that wasn't leaves the next one full too.
	switch {
	case incremental && changesComplete:
		since = started
	case !incremental && freshComplete:
		since, fullAt = started, started
	case !incremental:
		since = 0
	}
	wt.saveLists(lists, since, fullAt)
	wt.buildAccounts(ctx, started, ownerLists, ownersWhole, lists)
	phase, size = "saved", len(newWot)
	debug.FreeOSMemory()
}

// WebShape reports the depth this graph was built at, how many follows it
// holds and how many second-layer people have a vouch count (0 at depth 2,
// or before the graph is built). Underrated reads it to tell a follows-only
// web from one where nobody qualified.
func (wt *SimpleInMemory) WebShape() (depth, follows, vouched int) {
	depth = wt.WotDepth
	if l := wt.layers.Load(); l != nil {
		follows, vouched = len(l.follows), len(l.vouches)
	}
	return depth, follows, vouched
}

// Reach reports how many of the owners' follows follow pubkey (the vouches
// of the depth-3 pass), and whether pubkey is one of those follows. A follow
// has no vouch count: the pass counts only the second layer. known is false
// when the graph has no vouch counts (depth 2, or not built yet).
func (wt *SimpleInMemory) Reach(pubkey string) (vouches int, follow bool, known bool) {
	l := wt.layers.Load()
	if l == nil || len(l.follows) == 0 {
		return 0, false, false
	}
	if _, ok := slices.BinarySearch(l.follows, pubkey); ok {
		return 0, true, true
	}
	if l.vouches == nil {
		return 0, false, false
	}
	return l.vouches[pubkey], false, true
}
