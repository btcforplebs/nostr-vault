package wot

import (
	"context"
	"log/slog"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// Zombies: follows who have signed nothing for a long time (Plebs vs.
// Zombies' idea, github.com/dmnyc/plebs-vs-zombies, with its developer's OK).
//
// Any signed event of any kind counts as alive. Plebs vs. Zombies asks for a
// fixed list of kinds and so called people zombies who were busy with kind
// 30443 or 17 (dry run on Logen's follows, 2026-10-31, in
// RESEARCH/NV_ZOMBIES_PLAN.md); asking with no kinds at all has no such gap.
//
// A follow list (kind 3) seen while building the web is a floor, not a
// last-seen: the copy the build saw can be months older than the person's
// latest note. It only ever moves last-seen later, and a follow whose only
// date is an old kind 3 is still asked about on the public relays.
//
// This only counts and lists; it signs and publishes nothing. The apps send
// people to Plebs vs. Zombies to clean up (Logen 2026-11-01).

const (
	day = int64(24 * 60 * 60)
	// ZombieFreshDays starts the count: Plebs vs. Zombies' default "Fresh"
	// (Logen 2026-10-31, superseding 120).
	ZombieFreshDays   = 90
	ZombieRottingDays = 180
	ZombieAncientDays = 365
	// zombieAuthorsPerReq keeps a quiet author's few events from being
	// crowded out of a relay's limit by the others in the same REQ.
	zombieAuthorsPerReq = 50
	zombieReqLimit      = 500
	// zombieOutboxRelaysPer is how many of each quiet follow's write relays
	// are asked, and zombieOutboxRelaysMax how many in all.
	zombieOutboxRelaysPer = 3
	zombieOutboxRelaysMax = 40
	zombieFetchTimeout    = 8 * time.Second
	// ZombieCacheFor is how long a finished check is reused.
	ZombieCacheFor = 24 * time.Hour
)

// ZombieRelays are always asked besides the seed relays: the big public
// relays most people's notes reach. damus refused the dry run from the house
// IP but answers phones.
var ZombieRelays = []string{
	"wss://relay.damus.io",
	"wss://relay.primal.net",
	"wss://relay.snort.social",
	"wss://relay.nos.social",
}

// Bucket names, as Plebs vs. Zombies has them.
const (
	BucketFresh   = "fresh"
	BucketRotting = "rotting"
	BucketAncient = "ancient"
)

// ZombieBucket is the bucket for a follow quiet for `quietDays`, or "" when
// they are not a zombie (quiet under ZombieFreshDays).
func ZombieBucket(quietDays int) string {
	switch {
	case quietDays >= ZombieAncientDays:
		return BucketAncient
	case quietDays >= ZombieRottingDays:
		return BucketRotting
	case quietDays >= ZombieFreshDays:
		return BucketFresh
	}
	return ""
}

// Seen is the newest sign of life known for one pubkey.
type Seen struct {
	// At is the event's created_at, 0 when nothing at all was found.
	At int64 `json:"at"`
	// Kind is the kind of that event.
	Kind int `json:"kind"`
	// Floor: the date is a follow list the web build saw, nothing newer was
	// found, so the person may have been active later than this.
	Floor bool `json:"floor,omitempty"`
}

// newer reports whether s is a later sign of life than than.
func (s Seen) newer(than Seen) bool { return s.At > than.At }

// Zombie is one quiet follow.
type Zombie struct {
	Pubkey   string `json:"pubkey"`
	LastSeen int64  `json:"last_seen"`
	Kind     int    `json:"kind"`
	Floor    bool   `json:"floor,omitempty"`
	Days     int    `json:"days"`
	Bucket   string `json:"bucket"`
}

// ZombieReport is one finished check.
type ZombieReport struct {
	Owner     string   `json:"owner"`
	Follows   int      `json:"follows"`
	Fresh     int      `json:"fresh"`
	Rotting   int      `json:"rotting"`
	Ancient   int      `json:"ancient"`
	Zombies   []Zombie `json:"zombies"`
	CheckedAt int64    `json:"checked_at"`
	// Took is how long the check ran, in milliseconds.
	Took int64 `json:"took_ms"`
}

// ZombieCheck finds the quiet ones among follows. Every dependency is a
// function so the test runs it without a network.
type ZombieCheck struct {
	Now func() time.Time
	// Local returns the newest event per author this device already stores,
	// of any kind. May be nil.
	Local func(ctx context.Context, authors []string) map[string]Seen
	// Floors are follow-list dates from the web build (FollowListDates).
	Floors map[string]int64
	// Fetch asks relays one filter and returns what came back.
	Fetch func(ctx context.Context, relays []string, f nostr.Filter) []*nostr.Event
	// Relays are the public relays asked for everyone still quiet.
	Relays []string
}

// Run checks follows and returns the report. Follows are hex pubkeys; the
// owner is not counted.
func (z ZombieCheck) Run(ctx context.Context, owner string, follows []string) ZombieReport {
	started := time.Now()
	now := z.Now().Unix()
	// The window is the last ZombieFreshDays days, not counting the first
	// second: someone last seen exactly 90 days ago is Fresh, not alive.
	since := nostr.Timestamp(now - ZombieFreshDays*day + 1)
	follows = cleanFollows(owner, follows)

	seen := make(map[string]Seen, len(follows))
	note := func(pk string, s Seen) {
		if s.newer(seen[pk]) {
			seen[pk] = s
		}
	}
	if z.Local != nil {
		for pk, s := range z.Local(ctx, follows) {
			s.Floor = false
			note(pk, s)
		}
	}
	for _, pk := range follows {
		if at, ok := z.Floors[pk]; ok {
			note(pk, Seen{At: at, Kind: nostr.KindFollowList, Floor: true})
		}
	}
	// A floor never clears someone from the public check unless it is
	// itself inside the window: it is a real event they signed.
	quiet := func() []string {
		var out []string
		for _, pk := range follows {
			if seen[pk].At < int64(since) {
				out = append(out, pk)
			}
		}
		return out
	}
	record := func(evs []*nostr.Event, want map[string]bool) {
		for _, ev := range evs {
			if ev == nil || !want[ev.PubKey] {
				continue
			}
			note(ev.PubKey, Seen{At: int64(ev.CreatedAt), Kind: ev.Kind})
		}
	}
	sweep := func(relays []string, authors []string, windowed bool) {
		if len(relays) == 0 || z.Fetch == nil {
			return
		}
		for batch := range slices.Chunk(authors, zombieAuthorsPerReq) {
			if ctx.Err() != nil {
				return
			}
			f := nostr.Filter{Authors: batch, Limit: zombieReqLimit}
			if windowed {
				f.Since = &since
			}
			want := make(map[string]bool, len(batch))
			for _, pk := range batch {
				want[pk] = true
			}
			record(z.Fetch(ctx, relays, f), want)
		}
	}

	// 1: anything inside the window on the big relays.
	relays := uniqRelays(z.Relays)
	sweep(relays, quiet(), true)

	// 2: their own write relays (NIP-65), inside the window.
	outbox := z.writeRelays(ctx, relays, quiet())
	sweep(outbox, quiet(), true)

	// 3: still quiet: when did they last sign anything at all?
	sweep(uniqRelays(append(slices.Clone(relays), outbox...)), quiet(), false)

	report := ZombieReport{Owner: owner, Follows: len(follows), CheckedAt: now}
	for _, pk := range quiet() {
		s := seen[pk]
		days := ZombieAncientDays
		if s.At > 0 {
			days = int((now - s.At) / day)
		}
		bucket := ZombieBucket(days)
		if bucket == "" {
			continue
		}
		switch bucket {
		case BucketFresh:
			report.Fresh++
		case BucketRotting:
			report.Rotting++
		case BucketAncient:
			report.Ancient++
		}
		report.Zombies = append(report.Zombies, Zombie{
			Pubkey: pk, LastSeen: s.At, Kind: s.Kind, Floor: s.Floor, Days: days, Bucket: bucket,
		})
	}
	// Quiet longest first; nothing found at all is the longest.
	slices.SortStableFunc(report.Zombies, func(a, b Zombie) int {
		if a.LastSeen != b.LastSeen {
			if a.LastSeen < b.LastSeen {
				return -1
			}
			return 1
		}
		return strings.Compare(a.Pubkey, b.Pubkey)
	})
	if report.Zombies == nil {
		report.Zombies = []Zombie{}
	}
	report.Took = time.Since(started).Milliseconds()
	return report
}

// writeRelays are the quiet follows' NIP-65 write relays, a few each.
func (z ZombieCheck) writeRelays(ctx context.Context, relays []string, authors []string) []string {
	if len(authors) == 0 || len(relays) == 0 || z.Fetch == nil {
		return nil
	}
	newest := map[string]*nostr.Event{}
	for batch := range slices.Chunk(authors, zombieAuthorsPerReq*5) {
		for _, ev := range z.Fetch(ctx, relays, nostr.Filter{Kinds: []int{nostr.KindRelayListMetadata}, Authors: batch}) {
			if ev != nil && ev.Kind == nostr.KindRelayListMetadata && (newest[ev.PubKey] == nil || ev.CreatedAt > newest[ev.PubKey].CreatedAt) {
				newest[ev.PubKey] = ev
			}
		}
	}
	known := map[string]bool{}
	for _, r := range relays {
		known[normRelay(r)] = true
	}
	var out []string
	for _, pk := range authors {
		ev := newest[pk]
		if ev == nil {
			continue
		}
		taken := 0
		for tag := range ev.Tags.FindAll("r") {
			if taken >= zombieOutboxRelaysPer || len(out) >= zombieOutboxRelaysMax {
				break
			}
			if len(tag) > 2 && tag[2] == "read" {
				continue
			}
			url := normRelay(tag[1])
			if !strings.HasPrefix(url, "wss://") || known[url] {
				continue
			}
			known[url] = true
			out = append(out, url)
			taken++
		}
	}
	return out
}

func normRelay(url string) string {
	return strings.TrimRight(strings.ToLower(strings.TrimSpace(url)), "/")
}

func uniqRelays(relays []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, r := range relays {
		n := normRelay(r)
		if n == "" || seen[n] {
			continue
		}
		seen[n] = true
		out = append(out, n)
	}
	return out
}

// cleanFollows drops the owner, blanks, malformed keys and repeats.
func cleanFollows(owner string, follows []string) []string {
	seen := map[string]bool{strings.ToLower(owner): true}
	var out []string
	for _, pk := range follows {
		pk = strings.ToLower(strings.TrimSpace(pk))
		if len(pk) != 64 || seen[pk] {
			continue
		}
		seen[pk] = true
		out = append(out, pk)
	}
	return out
}

// PoolFetch is ZombieCheck.Fetch over a relay pool, each ask capped at
// zombieFetchTimeout.
func PoolFetch(pool *nostr.SimplePool) func(ctx context.Context, relays []string, f nostr.Filter) []*nostr.Event {
	return func(ctx context.Context, relays []string, f nostr.Filter) []*nostr.Event {
		ctx, cancel := context.WithTimeout(ctx, zombieFetchTimeout)
		defer cancel()
		var out []*nostr.Event
		for ev := range pool.FetchMany(ctx, relays, f) {
			out = append(out, ev.Event)
		}
		return out
	}
}

// ZombieState is what the apps read: the last report for the owner, if any,
// and whether a check is running.
type ZombieState struct {
	Checking bool          `json:"checking"`
	Report   *ZombieReport `json:"report,omitempty"`
}

type zombieCache struct {
	mu       sync.Mutex
	reports  map[string]ZombieReport
	checking map[string]bool
}

var zombies = zombieCache{reports: map[string]ZombieReport{}, checking: map[string]bool{}}

// Zombies returns owner's last report and starts a check (in spawn) when there
// is none, it is older than ZombieCacheFor, or force is set. run does the
// check; it is called at most once at a time per owner.
func Zombies(owner string, force bool, now time.Time, spawn func(name string, fn func()), run func() (ZombieReport, bool)) ZombieState {
	zombies.mu.Lock()
	defer zombies.mu.Unlock()
	report, has := zombies.reports[owner]
	stale := !has || now.Sub(time.Unix(report.CheckedAt, 0)) >= ZombieCacheFor
	if (stale || force) && !zombies.checking[owner] {
		zombies.checking[owner] = true
		spawn("wot-zombies", func() {
			result, ok := run()
			zombies.mu.Lock()
			defer zombies.mu.Unlock()
			delete(zombies.checking, owner)
			if ok {
				zombies.reports[owner] = result
				slog.Info("🧟 zombie check", "follows", result.Follows, "quiet", len(result.Zombies), "ms", result.Took)
			}
		})
	}
	state := ZombieState{Checking: zombies.checking[owner]}
	if has {
		state.Report = &report
	}
	return state
}

// resetZombies clears the cache (tests).
func resetZombies() {
	zombies.mu.Lock()
	defer zombies.mu.Unlock()
	zombies.reports = map[string]ZombieReport{}
	zombies.checking = map[string]bool{}
}
