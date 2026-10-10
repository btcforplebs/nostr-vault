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
	"sync/atomic"
	"time"

	"github.com/nbd-wtf/go-nostr"
	"github.com/puzpuzpuz/xsync/v4"

	"github.com/barrydeen/haven/pkg/runsafe"
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
const wotCacheVersion = 3

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

	// Dependencies for Refresh
	Pool               *nostr.SimplePool
	WhitelistedPubKeys map[string]struct{}

	SeedRelays      []string
	WotDepth        int
	MinFollowers    int
	WotFetchTimeout int
	CachePath       string
	CacheTTLMinutes int
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
	// A depth-3 graph built before the links file existed: rebuild once so
	// the apps can draw lines without asking relays.
	if wt.WotDepth >= 3 {
		if _, err := os.Stat(wt.linksPath()); err != nil {
			slog.Info("🔁 WoT cache has no links file, rebuilding")
			return false, 0
		}
	}

	wt.pubkeys.Store(&cache.Pubkeys)
	wt.layers.Store(&layers{follows: cache.Follows, vouches: cache.Vouches})
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

	cache := wotCache{
		Pubkeys:   *m,
		Timestamp: time.Now().Unix(),
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

	if err := os.WriteFile(wt.CachePath, data, 0644); err != nil {
		slog.Error("🚫 Failed to write WoT cache", "error", err)
		return
	}

	slog.Debug("💾 Saved WoT cache", "pubkeys", len(*m))
}

func (wt *SimpleInMemory) linksPath() string {
	return filepath.Join(filepath.Dir(wt.CachePath), linksFile)
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

// build is Refresh's work; the caller holds claimRefresh and build releases it.
func (wt *SimpleInMemory) build(ctx context.Context) {
	phase, size := "stopped", 0
	defer func() { releaseRefresh(phase, size) }()

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
		wt.SaveCache()
		wt.saveLinks(nil, nil)
		phase, size = "saved", len(newWot)
		return
	}

	timeout := time.Duration(wt.WotFetchTimeout) * time.Second
	timeoutCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	filter := nostr.Filter{
		Authors: slices.Collect(maps.Keys(wt.WhitelistedPubKeys)),
		Kinds:   []int{nostr.KindFollowList},
	}

	slog.Info("🛜 fetching Nostr events to build WoT")

	events := wt.Pool.FetchMany(timeoutCtx, wt.SeedRelays, filter)
	for ev := range latestEventByKindAndPubkey(timeoutCtx, events, &eventsAnalysed) {
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

	if wt.WotDepth == 2 {
		wt.layers.Store(&layers{follows: follows})
		slog.Info("🕸️ analysed Nostr events", "count", eventsAnalysed.Load())
		slog.Info("📈 direct followers in import relays", "🫂pubkeys", len(newWot), "🔗relays", len(wt.SeedRelays))
		wt.pubkeys.Store(&newWot)
		wt.SaveCache()
		wt.saveLinks(nil, nil)
		phase, size = "saved", len(newWot)
		return
	}

	slog.Info("🕸️ analysing Nostr events", "count", eventsAnalysed.Load())

	// Split analysis into batches of listBatchSize pubkeys and process them sequentially
	// Process sequentially with yielding to avoid blocking the host app's UI/Events
	keys := follows
	// Someone is in at MinFollowers; 0 and 1 both mean "any one follow".
	bar := max(int64(wt.MinFollowers), 1)
	followIndex := make(map[string]int, len(follows))
	for i, pk := range follows {
		followIndex[pk] = i
	}
	links := make(map[string][]int)
	slog.Info("🕸️ starting deeper Web of Trust analysis", "total_keys", len(keys))
	updateProgress(func(p *Progress) {
		p.Phase = "lists"
		p.Batches = (len(keys) + listBatchSize - 1) / listBatchSize
		p.Lists = eventsAnalysed.Load()
	})

	for batch := range slices.Chunk(keys, listBatchSize) {
		select {
		case <-ctx.Done():
			return
		default:
			timeoutCtx, cancel := context.WithTimeout(ctx, timeout)

			filter := nostr.Filter{
				Authors: batch,
				Kinds:   []int{nostr.KindFollowList},
			}

			events := wt.Pool.FetchMany(timeoutCtx, wt.SeedRelays, filter)
			for ev := range latestEventByKindAndPubkey(timeoutCtx, events, &eventsAnalysed) {
				from, isFollow := followIndex[ev.PubKey]
				for contact := range ev.Tags.FindAll("p") {
					if len(contact) > 1 {
						// One list's tags arrive together, so a repeated tag
						// is always the last index added.
						if l := links[contact[1]]; isFollow && contact[1] != ev.PubKey && (len(l) == 0 || l[len(l)-1] != from) {
							links[contact[1]] = append(l, from)
						}
						followers, _ := pubkeyFollowers.LoadOrStore(contact[1], &atomic.Int64{})
						// Report the moment someone clears the bar, so the
						// apps can show the web filling in instead of waiting
						// out the whole rebuild.
						if followers.Add(1) == bar && !newWot[contact[1]] {
							found(contact[1], previous)
						}
					}
				}
			}
			cancel()
			updateProgress(func(p *Progress) {
				p.BatchesDone++
				p.Lists = eventsAnalysed.Load()
			})

			// Only log every batch to avoid flooding the UI thread
			slog.Info("🕸️ verified identities in community", "count", eventsAnalysed.Load())

			// Yield to the OS scheduler and other goroutines to keep the host app responsive
			time.Sleep(100 * time.Millisecond)
		}
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

	for pk, from := range links {
		if _, owner := wt.WhitelistedPubKeys[pk]; owner || !newWot[pk] {
			delete(links, pk)
			continue
		}
		slices.Sort(from)
	}

	wt.layers.Store(&layers{follows: follows, vouches: vouches})
	wt.pubkeys.Store(&newWot)
	wt.SaveCache()
	wt.saveLinks(follows, links)
	phase, size = "saved", len(newWot)
	debug.FreeOSMemory()
}

func latestEventByKindAndPubkey(ctx context.Context, events <-chan nostr.RelayEvent, counter *atomic.Int64) <-chan *nostr.Event {
	ch := make(chan *nostr.Event)
	go func() {
		// ch must close even if the body panics, otherwise the consumer
		// in Refresh() blocks forever.
		defer close(ch)
		runsafe.Run("wot.latestEventByKindAndPubkey", func() {
			latestEvents := make(map[string]*nostr.Event)
		collect:
			for ev := range events {
				select {
				case <-ctx.Done():
					// Stop collecting, but keep what arrived (see below).
					break collect
				default:
					counter.Add(1)
					key := fmt.Sprintf("%d:%s", ev.Kind, ev.PubKey)
					if old, ok := latestEvents[key]; !ok || ev.CreatedAt > old.CreatedAt {
						latestEvents[key] = ev.Event
					}
				}
			}
			// Hand over everything collected, even when ctx has expired. ctx is
			// the fetch timeout: FetchMany only closes once every seed relay
			// has sent EOSE, so one slow or dead relay makes the timeout the
			// normal way a batch ends. Selecting on ctx.Done here dropped what
			// the healthy relays had already sent (Go picks a ready case at
			// random), which emptied the depth-3 graph. The consumer in
			// Refresh always drains ch, so these sends cannot block for good.
			for _, ev := range latestEvents {
				ch <- ev
			}
		})
	}()
	return ch
}
