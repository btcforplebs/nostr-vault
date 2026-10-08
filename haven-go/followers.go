package main

import (
	"context"
	"log"
	"maps"
	"slices"
	"sync"
	"sync/atomic"
	"time"

	"github.com/barrydeen/haven/internal/followers"
	"github.com/barrydeen/haven/pkg/runsafe"
	"github.com/barrydeen/haven/pkg/wot"
	"github.com/nbd-wtf/go-nostr"
)

// followerLedger is the live cycle's follower ledger; nil while the relay is
// stopped (or the ledger failed to open). See internal/followers.
var followerLedger atomic.Pointer[followers.Ledger]

const (
	// followerSweepEvery is how often known followers' latest lists are
	// re-read to catch unfollows, which a #p subscription can never deliver.
	followerSweepEvery = 6 * time.Hour
	// followerSweepBatch bounds the authors per REQ; relays cap filter size.
	followerSweepBatch = 250
	// followerFetchTimeout bounds the startup backfill and each sweep batch.
	followerFetchTimeout = 60 * time.Second
	followerFlushEvery   = 30 * time.Second
	// followerBackfillPages bounds each relay's until-paging; with
	// followerBackfillPageSize that is 100k lists per relay.
	followerBackfillPages    = 200
	followerBackfillPageSize = 500
)

// observeFollowList feeds a kind-3 list into the follower ledger. Called
// before Web-of-Trust filtering on every inbox path, so the ledger also sees
// followers whose events the inbox itself rejects; tiers sort them later.
func observeFollowList(ev *nostr.Event) {
	if ev == nil || ev.Kind != nostr.KindFollowList {
		return
	}
	l := followerLedger.Load()
	if l == nil || isBlacklisted(ev.PubKey) {
		return
	}
	tagged := make(map[string]struct{})
	size := 0
	for tag := range ev.Tags.FindAll("p") {
		if len(tag) < 2 {
			continue
		}
		size++
		if _, ok := config.WhitelistedPubKeys[tag[1]]; ok {
			tagged[tag[1]] = struct{}{}
		}
	}
	for owner := range config.WhitelistedPubKeys {
		_, tagsOwner := tagged[owner]
		switch l.ObserveList(owner, ev.PubKey, int64(ev.CreatedAt), tagsOwner, size) {
		case followers.New:
			log.Println("👤 new follower", ev.PubKey)
			emitFollowNotify(l, ev, owner)
		case followers.Returning:
			log.Println("👤 returning follower", ev.PubKey)
			emitFollowNotify(l, ev, owner)
		case followers.Unfollow:
			log.Println("👤 unfollowed by", ev.PubKey)
		}
	}
}

// emitFollowNotify raises a "type=follow" notification marker (format in
// emitInboxNotify) for a follow the ledger just watched happen. The ledger has
// already dropped republishes, flaps and follows that predate it, so each
// follower notifies once. Spam-tier followers (follow-everyone lists, constant
// republishers — followers.Classify) and old lists stay silent;
// the app applies the account's Follows switch and the Web of Trust gate.
// Not gated on NOTIFY_KINDS: kind 3 is never in it (the catch-up summary does
// not count follows), and the marker is only ever this one line.
func emitFollowNotify(l *followers.Ledger, ev *nostr.Event, owner string) {
	if l.Spam(owner, ev.PubKey) || !isNotifyableAge(ev) {
		return
	}
	log.Printf("🔔NOTIFY|type=follow|kind=%d|author=%s|id=%s|recipient=%s|preview=", ev.Kind, ev.PubKey, ev.ID, owner)
}

// followerCycleMu serialises ledger owners across relay stop/start cycles.
// StopRelayC waits only briefly for goroutines, so an old cycle can still be
// flushing when the next one opens the file; holding this for the whole run
// makes the new cycle read what the old one wrote last.
var followerCycleMu sync.Mutex

// runFollowerLedger owns the ledger for one relay cycle: open, backfill the
// lists that already tag the owner(s), then sweep for unfollows and flush
// until ctx ends.
func runFollowerLedger(ctx context.Context) {
	followerCycleMu.Lock()
	defer followerCycleMu.Unlock()
	if ctx.Err() != nil {
		return
	}
	owners := slices.Collect(maps.Keys(config.WhitelistedPubKeys))
	l, err := followers.Open(fs, config.FollowersPath, owners)
	if err != nil {
		log.Println("⚠️ follower ledger unavailable:", err)
		return
	}
	followerLedger.Store(l)
	defer func() {
		followerLedger.CompareAndSwap(l, nil)
		if err := l.Flush(); err != nil {
			log.Println("⚠️ follower ledger flush:", err)
		}
	}()

	// Backfill once per owner, not per launch: afterwards the live
	// subscription and the catch-up rounds deliver every new list. Retried
	// on later cycles until one completes.
	if pending := l.NeedsBackfill(); len(pending) > 0 {
		l.BeginBackfill(pending)
		runsafe.Run("followers.backfill", func() {
			if backfillFollowers(ctx, pending) {
				l.MarkBackfilled(pending)
				// Nothing older to sweep: the backfill just read every list.
				l.MarkSwept()
				log.Println("👤 follower backfill complete")
			} else if ctx.Err() == nil {
				log.Println("⚠️ follower backfill incomplete; retrying next start")
			}
		})
	}

	// The sweep interval is checked against the persisted last sweep, not a
	// ticker started with the cycle: a phone's relay rarely stays up six
	// hours straight, and a per-cycle ticker would then never fire.
	check := time.NewTicker(followerFlushEvery)
	defer check.Stop()
	for {
		if l.SweepDue(followerSweepEvery) {
			runsafe.Run("followers.sweep", func() {
				if sweepFollowers(ctx, l, owners) {
					l.MarkSwept()
				}
			})
		}
		select {
		case <-ctx.Done():
			return
		case <-check.C:
			if err := l.Flush(); err != nil {
				log.Println("⚠️ follower ledger flush:", err)
			}
		}
	}
}

// backfillFollowers pages back through every list the seed relays hold that
// tags an owner. Lists older than the ledger's seed land as "existing", not
// as news; a long-time follower missed here would read as "new" the next
// time they edit their list. Each relay is paged on its own: relays cap a
// REQ at different depths, so one shared "until" skips whatever only the
// shallower relay holds.
//
// Reports success when enough relays were paged to the end (see
// backfillQuorum) and ctx is still live.
func backfillFollowers(ctx context.Context, owners []string) bool {
	var done atomic.Int32
	var wg sync.WaitGroup
	for _, url := range config.ImportSeedRelays {
		wg.Add(1)
		runsafe.Go("followers.backfill.relay", func() {
			defer wg.Done()
			if backfillRelay(ctx, url, owners) {
				done.Add(1)
			}
		})
	}
	wg.Wait()
	need := min(backfillQuorum, len(config.ImportSeedRelays))
	return ctx.Err() == nil && need > 0 && int(done.Load()) >= need
}

// backfillQuorum is how many seed relays must be paged to the end before a
// backfill counts as done. One reachable relay is too thin a view.
const backfillQuorum = 2

// backfillRelay pages one relay back to its oldest matching list. Reports
// whether it reached the end (no timeout, no connection failure, page cap
// not hit).
func backfillRelay(ctx context.Context, url string, owners []string) bool {
	relay, err := pool.EnsureRelay(url)
	if err != nil {
		return false
	}
	seen := make(map[string]struct{})
	var until *nostr.Timestamp
	for page := 0; page < followerBackfillPages; page++ {
		qctx, cancel := context.WithTimeout(ctx, followerFetchTimeout)
		filter := nostr.Filter{Kinds: []int{nostr.KindFollowList}, Tags: nostr.TagMap{"p": owners},
			Until: until, Limit: followerBackfillPageSize}
		evs, err := relay.QuerySync(qctx, filter)
		timedOut := qctx.Err() != nil
		cancel()
		if err != nil || timedOut {
			return false
		}
		// "until" is inclusive and the page repeats its boundary second, so
		// the relay is exhausted when a page brings nothing unseen.
		fresh := 0
		oldest := nostr.Now()
		for _, ev := range evs {
			if ev.CreatedAt < oldest {
				oldest = ev.CreatedAt
			}
			if _, dup := seen[ev.ID]; dup {
				continue
			}
			seen[ev.ID] = struct{}{}
			fresh++
			observeFollowList(ev)
		}
		if fresh == 0 {
			return true
		}
		if until != nil && oldest >= *until {
			oldest = *until - 1 // a whole page in one second: step past it
		}
		until = &oldest
	}
	return false
}

// sweepFollowers re-reads the latest list of every current follower, so a
// list that dropped the owner is recorded as an unfollow. Reports whether
// every batch ran (ctx not cancelled).
func sweepFollowers(ctx context.Context, l *followers.Ledger, owners []string) bool {
	seen := make(map[string]struct{})
	var authors []string
	for _, o := range owners {
		for _, pk := range l.SweepTargets(o) {
			if _, dup := seen[pk]; !dup {
				seen[pk] = struct{}{}
				authors = append(authors, pk)
			}
		}
	}
	for batch := range slices.Chunk(authors, followerSweepBatch) {
		if ctx.Err() != nil {
			return false
		}
		bctx, cancel := context.WithTimeout(ctx, followerFetchTimeout)
		filter := nostr.Filter{Kinds: []int{nostr.KindFollowList}, Authors: batch}
		for ev := range pool.FetchMany(bctx, config.ImportSeedRelays, filter) {
			observeFollowList(ev.Event)
		}
		cancel()
	}
	return ctx.Err() == nil
}

// followersSnapshot is the app-facing follower view for owner (hex).
func followersSnapshot(ctx context.Context, owner string) (followers.Snapshot, bool) {
	l := followerLedger.Load()
	if l == nil {
		return followers.Snapshot{}, false
	}
	model := wot.GetInstance()
	return l.Snapshot(owner, func(pk string) bool { return model != nil && model.Has(ctx, pk) }), true
}
