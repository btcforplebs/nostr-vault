package main

// Local-first feed cache sync.
//
// The /feed relay (feedDB) holds the owner's follows' recent notes so client
// apps can render every feed view from localhost instantly — cold start, tab
// switches, and pagination — while their own live subscriptions stay
// real-time. This file keeps feedDB converged with the external feed relays:
// NIP-77 negentropy reconciliation where supported, watermark REQ catch-up
// elsewhere, plus an age-based prune so a phone's disk footprint stays flat.
//
// Unlike the inbox sync there is no tombstone set here: the store accepts
// everything matching {authors: follows, kinds: feed} — the local set is the
// same set the remote holds for that filter, so reconciliation converges
// without rejects. Mutes/blocks stay a client-side rendering concern.

import (
	"context"
	"errors"
	"fmt"
	"log"
	"log/slog"
	"maps"
	"runtime/debug"
	"slices"
	"sync/atomic"
	"time"

	"github.com/fiatjaf/eventstore"
	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/internal/negsync"
	"github.com/barrydeen/haven/pkg/runsafe"
)

// KindComment (NIP-22) carries replies from clients that have moved off kind 1
// replies; the apps only show the ones on kind 1 notes. KindPoll is a NIP-88
// poll, which the apps draw in the feed; its votes are fetched per poll.
// KindPicture is a NIP-68 picture post.
const (
	KindPoll    = 1068
	KindPicture = 20
)

// commonFeedKinds are the kinds a follow set posts all day long.
var commonFeedKinds = []int{nostr.KindTextNote, nostr.KindRepost, nostr.KindComment}

// rareFeedKinds are posted a few times a day across a whole follow set:
// articles, polls, generic reposts (an article, picture or poll someone
// boosted), pictures and highlights. They are fetched in a REQ of their own.
// Relays cap every REQ (primal: 500 events), and in one REQ shared with the
// common kinds, notes fill that cap: for 1,031 follows 500 events was 3.6
// hours, so the cache went four days with no article in it while the people
// followed published eight (2026-10-13).
var rareFeedKinds = []int{nostr.KindArticle, KindPoll, nostr.KindGenericRepost, KindPicture, nostr.KindHighlights}

var feedKinds = slices.Concat(commonFeedKinds, rareFeedKinds)

// OnlyFeedKinds restricts writes on the /feed route to feed note kinds. The
// browser build's owner streams may also cache kind 0, the names and pictures
// of the people in the feed, which natively the apps keep themselves.
func OnlyFeedKinds(ctx context.Context, event *nostr.Event) (bool, string) {
	if slices.Contains(feedKinds, event.Kind) {
		return false, ""
	}
	if event.Kind == nostr.KindProfileMetadata && ownerStream(ctx) {
		return false, ""
	}
	return true, fmt.Sprintf("restricted: this relay only accepts feed notes (kinds %v)", feedKinds)
}

// feedCommonFilter and feedRareFilter are the plain-REQ catch-up, each kind
// set since its own watermark, so neither can push the other out of a
// relay's per-REQ cap.
func feedCommonFilter(authors []string, since nostr.Timestamp) nostr.Filter {
	return nostr.Filter{Authors: authors, Kinds: commonFeedKinds, Since: &since}
}

func feedRareFilter(authors []string, since nostr.Timestamp) nostr.Filter {
	return nostr.Filter{Authors: authors, Kinds: rareFeedKinds, Since: &since}
}

// feedSyncCh triggers an immediate feed sync round (pull-to-refresh).
// Buffered + coalesced like relaySyncCh.
var feedSyncCh = make(chan struct{}, 1)

// minSyncGap is the minimum spacing between on-demand sync rounds (inbox
// catch-up and feed sync). Each round dials fresh connections to every relay,
// so rapid pull-to-refresh must be absorbed, not amplified.
const minSyncGap = 60 * time.Second

// feedNegStore adapts feedDB for Down-direction negentropy sync. Publish
// re-applies the kind and follow-set gates so a misbehaving relay can't fill
// the cache with events outside the requested filter.
type feedNegStore struct {
	feed    eventstore.RelayWrapper
	follows map[string]struct{}
	advance func(nostr.Timestamp)
}

func (s *feedNegStore) QuerySync(ctx context.Context, f nostr.Filter) ([]*nostr.Event, error) {
	return s.feed.QuerySync(eventstore.SetNegentropy(ctx), f)
}

func (s *feedNegStore) QueryEvents(ctx context.Context, f nostr.Filter) (chan *nostr.Event, error) {
	return s.feed.QueryEvents(ctx, f)
}

func (s *feedNegStore) Publish(ctx context.Context, ev nostr.Event) error {
	if !slices.Contains(feedKinds, ev.Kind) {
		return nil
	}
	if _, ok := s.follows[ev.PubKey]; !ok {
		return nil
	}
	if err := s.feed.Publish(ctx, ev); err != nil {
		return err
	}
	if s.advance != nil {
		s.advance(ev.CreatedAt)
	}
	return nil
}

// feedShortHoldRounds: how many rounds in a row one relay stopping partway
// may hold the fallback watermark back. Past that the round counts as
// complete without it, or one relay that keeps going quiet (or a busy one
// that keeps hitting importMaxPages inside the window) pins the watermark for
// every relay and each hourly round re-reads the whole window from all of
// them (Tron, #1721).
const feedShortHoldRounds = 2

// feedFallbackPull reads filter from relays, each paged newest first until a
// page brings nothing older (fetchPaged), handing every note to publish. It
// used to be one request, so a relay's answer cap (often 500) was counted as
// the whole round. True when the round read everything: at least one relay
// answered, and no relay stopped partway, except one that has now stopped
// partway more than feedShortHoldRounds rounds in a row. shortRounds keeps
// those streaks across rounds (normalized URL → rounds); a relay that reads
// to the end, or isn't asked, drops out of it.
func feedFallbackPull(ctx context.Context, relays []string, filter nostr.Filter, publish func(*nostr.Event), shortRounds map[string]int) bool {
	// One entry per relay: two spellings of one relay (trailing slash, case)
	// would share a key and step its streak twice a round (Tron, #1721).
	asked := map[string]bool{}
	relays = slices.DeleteFunc(slices.Clone(relays), func(url string) bool {
		key := nostr.NormalizeURL(url)
		if asked[key] {
			return true
		}
		asked[key] = true
		return false
	})
	res := fetchPaged(ctx, relays, filter, importMaxPages, publish)
	if ctx.Err() != nil {
		return false
	}
	held := false
	for _, url := range relays {
		key := nostr.NormalizeURL(url)
		if !slices.Contains(res.Short, url) {
			delete(shortRounds, key)
			continue
		}
		shortRounds[key]++
		if shortRounds[key] <= feedShortHoldRounds {
			held = true
		} else if shortRounds[key] == feedShortHoldRounds+1 {
			log.Println("📚 feed catch-up: relay keeps stopping partway, no longer holding the watermark for it:", key)
		}
	}
	for key := range shortRounds {
		if !asked[key] {
			delete(shortRounds, key)
		}
	}
	return !held && len(res.Silent) < len(relays)
}

// ownerFollowSet derives the follow set from the owner's newest kind-3 in the
// outbox DB (which owner catch-up keeps current across devices).
func ownerFollowSet(ctx context.Context) map[string]struct{} {
	if config.OwnerPubKey == "" || outboxDB == nil {
		return nil
	}
	wdb := eventstore.RelayWrapper{Store: outboxDB}
	evs, err := wdb.QuerySync(ctx, nostr.Filter{
		Authors: []string{config.OwnerPubKey},
		Kinds:   []int{nostr.KindFollowList},
		Limit:   1,
	})
	if err != nil || len(evs) == 0 {
		return nil
	}
	follows := make(map[string]struct{})
	for tag := range evs[0].Tags.FindAll("p") {
		if len(tag) >= 2 && nostr.IsValidPublicKey(tag[1]) {
			follows[tag[1]] = struct{}{}
		}
	}
	return follows
}

// ownerFollowListStamp is the id of the newest kind-3 any owner on this relay
// has in the outbox DB, or "" when there is none. A new follow list is the
// newest by construction, so the owner-only WoT rebuild runs when this moves.
func ownerFollowListStamp() string {
	owners := slices.Collect(maps.Keys(config.WhitelistedPubKeys))
	if len(owners) == 0 || outboxDB == nil {
		return ""
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	evs, err := eventstore.RelayWrapper{Store: outboxDB}.QuerySync(ctx, nostr.Filter{
		Authors: owners,
		Kinds:   []int{nostr.KindFollowList},
		Limit:   1,
	})
	if err != nil || len(evs) == 0 {
		return ""
	}
	return evs[0].ID
}

// ownerFollowLists are the owners' newest follow lists in the outbox DB, one
// per owner. The WoT build takes them over older copies on the seed relays.
func ownerFollowLists() []*nostr.Event {
	if len(config.WhitelistedPubKeys) == 0 || outboxDB == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var lists []*nostr.Event
	for owner := range config.WhitelistedPubKeys {
		evs, err := eventstore.RelayWrapper{Store: outboxDB}.QuerySync(ctx, nostr.Filter{
			Authors: []string{owner},
			Kinds:   []int{nostr.KindFollowList},
			Limit:   1,
		})
		if err == nil && len(evs) > 0 {
			lists = append(lists, evs[0])
		}
	}
	return lists
}

// ownerFollowListAt is when the newest of the owners' stored follow lists was
// made, or zero when there is none.
func ownerFollowListAt() time.Time {
	var newest nostr.Timestamp
	for _, ev := range ownerFollowLists() {
		newest = max(newest, ev.CreatedAt)
	}
	if newest == 0 {
		return time.Time{}
	}
	return newest.Time()
}

// feedSyncRelays picks the external relay set to reconcile the feed against:
// FEED_SYNC_RELAYS_FILE when configured, otherwise blastr ∪ import seed
// relays (the same relays the clients read their feeds from), minus the
// bulkReadExcludedHosts.
func feedSyncRelays() []string {
	if len(config.FeedSyncRelays) > 0 {
		return config.FeedSyncRelays
	}
	set := make(map[string]struct{})
	for _, r := range config.BlastrRelays {
		set[r] = struct{}{}
	}
	for _, r := range config.ImportSeedRelays {
		set[r] = struct{}{}
	}
	relays := make([]string, 0, len(set))
	for r := range set {
		relays = append(relays, r)
	}
	return withoutBulkReadExcluded(relays)
}

// syncFeed runs the feed-cache convergence loop for one relay cycle: an
// immediate round on start, then every INBOX_PULL_INTERVAL_SECONDS and on
// demand via feedSyncCh. Sequential per relay (mobile battery).
func syncFeed(ctx context.Context) {
	if !config.FeedSyncEnabled {
		return
	}

	wdbFeed := eventstore.RelayWrapper{Store: feedDB}

	windowSince := func() nostr.Timestamp {
		return nostr.Timestamp(time.Now().Add(-time.Duration(config.FeedSyncWindowDays) * 24 * time.Hour).Unix())
	}
	// Both watermarks are saved after every round (see syncstate.go), so a
	// restart resumes from the last round instead of the fixed start points.
	state := openSyncState(fs, feedSyncStateFile)

	// Fallback watermark for non-NIP-77 relays, same shape as the inbox one.
	var lastSeenFeed atomic.Int64
	lastSeenFeed.Store(state.mark("feed", time.Now().Add(-24*time.Hour).Unix(), int64(windowSince())))
	advance := func(ts nostr.Timestamp) {
		for {
			cur := lastSeenFeed.Load()
			if int64(ts) <= cur || lastSeenFeed.CompareAndSwap(cur, int64(ts)) {
				return
			}
		}
	}

	// The rare kinds' watermark starts at the window's edge: a fresh cache
	// gets the whole window of articles and polls in its first round, which
	// is a few dozen events, not the hours of notes the common pull starts
	// with.
	// Per relay: rounds in a row it stopped partway (feedFallbackPull).
	// Only runFeedSync touches it, one round at a time.
	feedShortRounds := map[string]int{}

	var lastSeenRare atomic.Int64
	lastSeenRare.Store(state.mark("feed_rare", int64(windowSince()), int64(windowSince())))

	runFeedSync := func() {
		// Captured before any fetching so events arriving mid-round aren't
		// skipped: the fallback query below re-queries from lastSeenFeed-60.
		roundStart := nostr.Timestamp(time.Now().Unix())
		follows := ownerFollowSet(ctx)
		if len(follows) == 0 {
			slog.Debug("feed sync: no follow list in outbox yet, skipping round")
			return
		}
		authors := make([]string, 0, len(follows))
		for pk := range follows {
			authors = append(authors, pk)
		}
		// No per-note advance: a note stored mid-round says nothing about
		// what is still missing below it. The watermark moves once, at the
		// end of a round that read everything (feedFallbackPull).
		store := &feedNegStore{feed: wdbFeed, follows: follows}
		relays := feedSyncRelays()

		since := windowSince()
		filter := nostr.Filter{Authors: authors, Kinds: feedKinds, Since: &since}

		rareDone := false
		rsince := nostr.Timestamp(lastSeenRare.Load() - 60)
		if rsince < since {
			rsince = since
		}
		rareFilter := feedRareFilter(authors, rsince)
		// The rare kinds go first, on their own clock: the common pull can
		// run for minutes (one round on a phone, 1,031 follows: over four)
		// and nothing behind it may wait on that. Every relay, not only the
		// fallback ones: a negentropy round against a relay that trims what
		// it lists would still miss them. A few dozen events a round.
		if ctx.Err() == nil {
			rctx, cancel := context.WithTimeout(ctx, 90*time.Second)
			received := 0
			for ev := range pool.FetchMany(rctx, relays, rareFilter) {
				received++
				store.Publish(ctx, *ev.Event)
			}
			timedOut := rctx.Err() != nil
			cancel()
			if ctx.Err() != nil {
				return
			}
			log.Printf("📚 feed rare-kinds pull since %s on %d relays: %d events", time.Unix(int64(rsince), 0).Format(time.RFC3339), len(relays), received)
			// Only a pass that finished moves the rare watermark.
			if !timedOut {
				rareDone = true
			}
		}

		var fallback []string
		if config.NegentropySyncEnabled {
			// One vector per round, reused across relays — the build
			// materializes the whole windowed feed cache, which dwarfs the
			// per-relay reconciliation cost (same rationale as runCatchup).
			feedVec, fvErr := negsync.BuildVector(ctx, store, filter)
			if fvErr != nil {
				slog.Warn("negentropy feed vector build failed, plain catch-up this round", "err", fvErr)
				fallback = relays
			} else {
				for _, url := range relays {
					if ctx.Err() != nil {
						return
					}
					if relayBanned(url) {
						continue
					}
					if !relaySupportsNegentropy(ctx, url) {
						fallback = append(fallback, url)
						continue
					}
					rctx, cancel := context.WithTimeout(ctx, 120*time.Second)
					stats, err := negsync.SyncWithVector(rctx, store, feedVec, url, filter, negsync.Down)
					cancel()
					switch {
					case err == nil:
						markNegentropySupported(url)
						log.Printf("📚 negentropy feed sync %s: %d new (local set %d)", url, stats.Downloaded, stats.LocalHave)
					case errors.Is(err, negsync.ErrUnsupported):
						markNegentropyUnsupported(url)
						fallback = append(fallback, url)
					case errors.Is(err, negsync.ErrRefused):
						// Deterministic per-filter refusal — cache like
						// unsupported instead of re-probing every round.
						slog.Warn("negentropy feed sync refused, plain catch-up until retry TTL", "relay", url, "err", err)
						markNegentropyUnsupported(url)
						noteRelayRefusal(url, err)
						fallback = append(fallback, url)
					default:
						noteRelayRefusal(url, err)
						slog.Warn("negentropy feed sync failed, plain catch-up this round", "relay", url, "err", err)
						fallback = append(fallback, url)
					}
				}
			}
		} else {
			fallback = relays
		}

		fsince := nostr.Timestamp(lastSeenFeed.Load() - 60)
		if fsince < since {
			fsince = since
		}
		commonFilter := feedCommonFilter(authors, fsince)
		complete := true
		if len(fallback) > 0 && ctx.Err() == nil {
			log.Println("📚 feed catch-up pull since", time.Unix(int64(fsince), 0).Format(time.RFC3339), "on", len(fallback), "relays")
			complete = feedFallbackPull(ctx, fallback, commonFilter, func(ev *nostr.Event) { store.Publish(ctx, *ev) }, feedShortRounds)
			if ctx.Err() != nil {
				return
			}
		}

		pruneFeed(ctx, wdbFeed)
		// Advance the fallback watermark to the start of this round when the
		// round read everything, whether or not anything was cached:
		// otherwise a quiet round leaves lastSeenFeed pinned in the past and
		// the next fallback pull re-queries an ever-widening window (expanding
		// downloads, 100% CPU). A round cut short (a relay stopped partway, or
		// none answered) keeps it, so the next round asks again for what this
		// one missed (Tidy import audit, item 8), for at most
		// feedShortHoldRounds rounds per relay; the window's edge (since)
		// still bounds how far back that can reach. Monotonic.
		if ctx.Err() == nil {
			if complete {
				advance(roundStart)
			} else {
				log.Println("📚 feed catch-up did not read everything; asking from the same point next round")
			}
			if rareDone {
				lastSeenRare.Store(int64(roundStart))
			}
			state.setMark("feed", lastSeenFeed.Load())
			state.setMark("feed_rare", lastSeenRare.Load())
			state.save()
		}
		// Same rationale as runCatchup: the vector build materializes the whole
		// windowed feed cache per relay; return the spike to the OS promptly.
		debug.FreeOSMemory()
	}

	pullEvery := config.InboxPullIntervalSeconds
	if pullEvery <= 0 {
		pullEvery = 3600
	}

	runsafe.Go("syncFeed.loop", func() {
		// First round shortly after start so a fresh install's cache fills
		// without waiting a full interval. The relay boot path stays fast.
		select {
		case <-ctx.Done():
			return
		case <-time.After(15 * time.Second):
		}
		runFeedSync()
		lastRun := time.Now()

		ticker := time.NewTicker(time.Duration(pullEvery) * time.Second)
		defer ticker.Stop()
		// Same overrun guard as the inbox catch-up loop: a round longer than
		// the tick interval must not chain straight into the next one, or the
		// loop pins the CPU with back-to-back full-cache scans forever.
		restartTicker := func() {
			select {
			case <-ticker.C:
			default:
			}
			ticker.Reset(time.Duration(pullEvery) * time.Second)
		}
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			case <-feedSyncCh:
				// Same throttle as the inbox catch-up: sync rounds dial fresh
				// connections per relay; rapid pull-to-refresh must not stack
				// rounds and starve the clients' own sockets.
				if time.Since(lastRun) < minSyncGap {
					slog.Debug("feed sync request throttled", "since_last", time.Since(lastRun))
					continue
				}
				log.Println("📚 feed sync requested (pull-to-refresh)")
			}
			runFeedSync()
			lastRun = time.Now()
			restartTicker()
		}
	})
}

// pruneFeed deletes cached feed events older than the sync window (plus one
// day of slack so reconciliation never sees a locally-pruned event as
// missing). Keeps the phone's feedDB footprint proportional to the window.
func pruneFeed(ctx context.Context, wdb eventstore.RelayWrapper) {
	cutoff := nostr.Timestamp(time.Now().Add(-time.Duration(config.FeedSyncWindowDays+1) * 24 * time.Hour).Unix())
	deleted := 0
	for range 20 { // bounded rounds so a huge backlog can't stall the loop
		evs, err := wdb.QuerySync(ctx, nostr.Filter{Until: &cutoff, Kinds: feedKinds, Limit: 500})
		if err != nil || len(evs) == 0 {
			break
		}
		for _, ev := range evs {
			if ctx.Err() != nil {
				return
			}
			if err := feedDB.DeleteEvent(ctx, ev); err == nil {
				deleted++
			}
		}
		if len(evs) < 500 {
			break
		}
	}
	if deleted > 0 {
		slog.Info("feed cache pruned", "deleted", deleted)
	}
}
