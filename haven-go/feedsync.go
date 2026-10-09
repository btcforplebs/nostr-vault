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
	"log"
	"log/slog"
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
const KindPoll = 1068

var feedKinds = []int{nostr.KindTextNote, nostr.KindRepost, nostr.KindArticle, nostr.KindComment, KindPoll}

// OnlyFeedKinds restricts writes on the /feed route to feed note kinds.
func OnlyFeedKinds(ctx context.Context, event *nostr.Event) (bool, string) {
	if slices.Contains(feedKinds, event.Kind) {
		return false, ""
	}
	return true, "restricted: this relay only accepts feed notes (kinds 1, 6, 30023, 1111, 1068)"
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

// feedSyncRelays picks the external relay set to reconcile the feed against:
// FEED_SYNC_RELAYS_FILE when configured, otherwise blastr ∪ import seed
// relays (the same relays the clients read their feeds from).
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
	return relays
}

// syncFeed runs the feed-cache convergence loop for one relay cycle: an
// immediate round on start, then every INBOX_PULL_INTERVAL_SECONDS and on
// demand via feedSyncCh. Sequential per relay (mobile battery).
func syncFeed(ctx context.Context) {
	if !config.FeedSyncEnabled {
		return
	}

	wdbFeed := eventstore.RelayWrapper{Store: feedDB}

	// Fallback watermark for non-NIP-77 relays, same shape as the inbox one.
	var lastSeenFeed atomic.Int64
	lastSeenFeed.Store(time.Now().Add(-24 * time.Hour).Unix())
	advance := func(ts nostr.Timestamp) {
		for {
			cur := lastSeenFeed.Load()
			if int64(ts) <= cur || lastSeenFeed.CompareAndSwap(cur, int64(ts)) {
				return
			}
		}
	}

	windowSince := func() nostr.Timestamp {
		return nostr.Timestamp(time.Now().Add(-time.Duration(config.FeedSyncWindowDays) * 24 * time.Hour).Unix())
	}

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
		store := &feedNegStore{feed: wdbFeed, follows: follows, advance: advance}
		relays := feedSyncRelays()

		since := windowSince()
		filter := nostr.Filter{Authors: authors, Kinds: feedKinds, Since: &since}

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
						fallback = append(fallback, url)
					default:
						slog.Warn("negentropy feed sync failed, plain catch-up this round", "relay", url, "err", err)
						fallback = append(fallback, url)
					}
				}
			}
		} else {
			fallback = relays
		}

		if len(fallback) > 0 && ctx.Err() == nil {
			fsince := nostr.Timestamp(lastSeenFeed.Load() - 60)
			if fsince < since {
				fsince = since
			}
			ffilter := nostr.Filter{Authors: authors, Kinds: feedKinds, Since: &fsince}
			log.Println("📚 feed catch-up pull since", time.Unix(int64(fsince), 0).Format(time.RFC3339), "on", len(fallback), "relays")
			for ev := range pool.FetchMany(ctx, fallback, ffilter) {
				if ctx.Err() != nil {
					return
				}
				store.Publish(ctx, *ev.Event)
			}
		}

		pruneFeed(ctx, wdbFeed)
		// Advance the fallback watermark to the start of this round regardless
		// of whether anything was cached. Otherwise a quiet round leaves
		// lastSeenFeed pinned in the past and the next fallback pull re-queries
		// an ever-widening window (expanding downloads, 100% CPU). Monotonic.
		if ctx.Err() == nil {
			advance(roundStart)
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
