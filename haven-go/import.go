package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"log/slog"
	"maps"
	"runtime/debug"
	"slices"
	"strings"
	"sync/atomic"
	"time"

	"github.com/fiatjaf/eventstore"
	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/internal/negsync"
	"github.com/barrydeen/haven/internal/tombstones"
	"github.com/barrydeen/haven/pkg/runsafe"
	"github.com/barrydeen/haven/pkg/wot"
)

const layout = "2006-01-02"

// giftWrapBackdateSlack is how far behind the watermark a NIP-59 gift wrap can
// legitimately land: the spec randomizes created_at up to 2 days into the past.
// The inbox fallback (non-NIP-77) catch-up floors its `since` here so backdated
// DMs aren't filtered out by the relay and silently missed. Bounded (2 days),
// so it never reintroduces an expanding-window pull. Plus a minute of overlap.
const giftWrapBackdateSlack = 2*24*time.Hour + time.Minute

// ensureImportRelays checks connectivity to all import seed relays.
// Returns false if ALL relays are unreachable (caller should abort).
// NOTE: never calls os.Exit — in C-shared / iOS embedded mode that would
// terminate the entire host app process.
func ensureImportRelays() bool {
	nErrors := 0
	log.Println("🧪 Testing import relays")
	for _, relay := range config.ImportSeedRelays {
		if _, err := pool.EnsureRelay(relay); err != nil {
			nErrors++
			slog.Error("🚫 Error connecting to relay", "relay", relay, "error", err)
		} else {
			slog.Debug("✅ Connected to relay", "relay", relay)
		}
	}
	if nErrors == 0 {
		slog.Info("✅ All relays connected successfully")
		return true
	} else if nErrors == len(config.ImportSeedRelays) {
		slog.Error("🚫 Unable to connect to any import relays, check your connectivity and relays_import.json file")
		return false
	} else {
		slog.Warn("⚠️ Some relays failed to connect, proceeding, but this may cause issues")
		slog.Info("ℹ️ If you always see this message during startup, consider removing the relays that are not working from your relays_import.json file")
		return true
	}
}

func runImport(ctx context.Context) {
	// NOTE: do NOT use flag.FlagSet / os.Args here — in C-shared (iOS embedded)
	// mode os.Args belongs to the host app and index [2:] is garbage.
	// All configuration is already loaded from environment variables by loadConfig().
	if err := GranularInitDBs([]string{"chat", "outbox", "inbox"}); err != nil {
		log.Println("🚫 failed to init import DBs:", err)
		return
	}
	wotModel := wot.NewSimpleInMemory(
		pool,
		config.WhitelistedPubKeys,
		config.ImportSeedRelays,
		config.WotDepth,
		config.WotMinimumFollowers,
		config.WotFetchTimeoutSeconds,
		config.WotCachePath,
		config.WotCacheTTLMinutes,
	).WithFallbackSeeds(loadStarterPack())

	// Try to load from cache first. MarkReady on the cache-hit path also
	// stores the instance, so GetInstance() below never returns nil.
	gate := wot.NewCycle()
	if cacheLoaded, _ := wotModel.LoadFromCache(); cacheLoaded {
		wot.MarkReady(gate, wotModel)
	} else {
		// Cache miss or invalid, initialize from network
		wot.Initialize(ctx, wotModel, gate)
	}

	log.Println("📦 importing notes")
	importOwnerNotes(ctx)
	importTaggedNotes(ctx)
}

func importOwnerNotes(ctx context.Context) {
	ownerImportedNotes := 0
	nFailedImportNotes := 0
	wdb := eventstore.RelayWrapper{Store: outboxDB}

	startTime, err := time.Parse(layout, config.ImportStartDate)
	if err != nil {
		fmt.Println("Error parsing start date:", err)
		return
	}
	endTime := startTime.Add(240 * time.Hour)

	for {
		startTimestamp := nostr.Timestamp(startTime.Unix())
		endTimestamp := nostr.Timestamp(endTime.Unix())

		filter := nostr.Filter{
			Authors: slices.Collect(maps.Keys(config.WhitelistedPubKeys)),
			Since:   &startTimestamp,
			Until:   &endTimestamp,
		}

		done := make(chan int, 1)
		timeout := time.Duration(config.ImportOwnerNotesFetchTimeoutSeconds) * time.Second
		ctx, cancel := context.WithTimeout(ctx, timeout)

		go func() {
			defer cancel()
			batchImportedNotes := 0

			// done must be signalled even if the fetch loop panics,
			// otherwise the select below waits out the full timeout.
			runsafe.Run("importOwnerNotes.fetch", func() {
				events := pool.FetchMany(ctx, config.ImportSeedRelays, filter)
				for ev := range events {
					if ctx.Err() != nil {
						break // Stop the loop on timeout
					}
					if isBlacklisted(ev.PubKey) {
						slog.Debug("🚫 skipping event from blacklisted pubkey", "pubkey", ev.PubKey, "id", ev.ID)
						continue
					}
					if err := wdb.Publish(ctx, *ev.Event); err != nil {
						log.Println("🚫  error importing note", ev.ID, ":", err)
						nFailedImportNotes++
					}
					batchImportedNotes++
				}
			})
			done <- batchImportedNotes
			close(done)
		}()

		select {
		case batchImportedNotes := <-done:
			ownerImportedNotes += batchImportedNotes
			if batchImportedNotes == 0 {
				log.Printf("ℹ️ No notes found for %s to %s", startTime.Format(layout), endTime.Format(layout))
			} else {
				log.Printf("📦 Imported %d notes from %s to %s", batchImportedNotes, startTime.Format(layout), endTime.Format(layout))
			}
		case <-ctx.Done():
			log.Printf("🚫 Timeout after %v while importing notes from %s to %s", timeout, startTime.Format(layout), endTime.Format(layout))
		}

		startTime = startTime.Add(240 * time.Hour)
		endTime = endTime.Add(240 * time.Hour)

		if startTime.After(time.Now()) {
			log.Println("✅ owner note import complete! Imported", ownerImportedNotes, "notes")
			break
		}
		if nFailedImportNotes > 0 {
			log.Printf("⚠️ Failed to import %d notes", nFailedImportNotes)
		}

		time.Sleep(1 * time.Second) // Avoid bombarding relays with too many requests
	}
	debug.FreeOSMemory()
}

func importTaggedNotes(ctx context.Context) {
	taggedImportedNotes := 0
	done := make(chan struct{}, 1)
	timeout := time.Duration(config.ImportTaggedNotesFetchTimeoutSeconds) * time.Second
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	wdbInbox := eventstore.RelayWrapper{Store: inboxDB}
	wdbChat := eventstore.RelayWrapper{Store: chatDB}
	filter := nostr.Filter{
		Tags: nostr.TagMap{
			"p": slices.Collect(maps.Keys(config.WhitelistedPubKeys)),
		},
	}

	log.Println("📦 importing inbox notes, please wait up to", timeout)

	go func() {
		// done must close even if the fetch loop panics, otherwise the
		// select below waits out the full timeout.
		defer close(done)
		runsafe.Run("importTaggedNotes.fetch", func() {
			events := pool.FetchMany(ctx, config.ImportSeedRelays, filter)
			for ev := range events {
				if ctx.Err() != nil {
					break // Stop the loop on timeout
				}

				if isBlacklisted(ev.PubKey) {
					slog.Debug("🚫 skipping tagged event from blacklisted pubkey", "pubkey", ev.PubKey, "id", ev.ID)
					continue
				}

				if !wot.GetInstance().Has(ctx, ev.PubKey) && ev.Kind != nostr.KindGiftWrap {
					continue
				}
				for tag := range ev.Tags.FindAll("p") {
					if len(tag) < 2 {
						continue
					}
					if _, ok := config.WhitelistedPubKeys[tag[1]]; ok {
						dbToWrite := wdbInbox
						if ev.Kind == nostr.KindGiftWrap {
							dbToWrite = wdbChat
						}
						if err := dbToWrite.Publish(ctx, *ev.Event); err != nil {
							log.Println("🚫 error importing tagged note", ev.ID, ":", err)
						}
						taggedImportedNotes++
					}
				}
			}
		})
	}()

	select {
	case <-done:
		log.Println("📦 imported", taggedImportedNotes, "tagged notes")
	case <-ctx.Done():
		log.Println("🚫 Timeout after", timeout, "while importing tagged notes")
	}

	log.Println("✅ tagged import complete")
	debug.FreeOSMemory()
}

func subscribeInboxAndChat(ctx context.Context) {
	// Wait for WoT to finish initializing before subscribing.
	// Without this, wot.Has() rejects all tagged notes as "not in WoT".
	log.Println("📢 waiting for Web of Trust before subscribing to inbox")
	wot.WaitReady(ctx)
	if ctx.Err() != nil {
		return
	}

	wdbInbox := eventstore.RelayWrapper{Store: inboxDB}
	wdbChat := eventstore.RelayWrapper{Store: chatDB}
	wdbOutbox := eventstore.RelayWrapper{Store: outboxDB}

	// Build deduplicated relay set: ImportSeedRelays + DmRelays
	relaySet := make(map[string]struct{})
	for _, r := range config.ImportSeedRelays {
		relaySet[r] = struct{}{}
	}
	for _, r := range config.DmRelays {
		relaySet[r] = struct{}{}
	}
	// The Mac relay's outbox is a seed relay (owner events, both directions)
	// and its inbox is inbox-only, like a DM relay. Added here rather than
	// trusted to the app's relay files so the Mac can't silently drop out.
	macBase, macInbox := macRelayURLs()
	if macBase != "" {
		relaySet[macBase] = struct{}{}
		relaySet[macInbox] = struct{}{}
	}
	relays := make([]string, 0, len(relaySet))
	for r := range relaySet {
		relays = append(relays, r)
	}

	pTags := slices.Collect(maps.Keys(config.WhitelistedPubKeys))

	// Watermarks of the newest event we've stored, one for tagged/inbox events
	// and one for the owner's own (outbox) events. Both the live subscription
	// and the periodic/on-demand catch-up resume from here, so a dropped
	// connection no longer loses events: on reconnect we backfill from the
	// watermark instead of a fixed 24h window.
	startTs := time.Now().Add(-24 * time.Hour).Unix()
	var lastSeen atomic.Int64      // tagged / inbox events
	var lastSeenOwner atomic.Int64 // owner-authored events
	lastSeen.Store(startTs)
	lastSeenOwner.Store(startTs)
	advance := func(wm *atomic.Int64, ts nostr.Timestamp) {
		for {
			cur := wm.Load()
			if int64(ts) <= cur {
				return
			}
			if wm.CompareAndSwap(cur, int64(ts)) {
				return
			}
		}
	}

	// Tombstones record events that were fetched and intentionally rejected so
	// negentropy sync never re-downloads them (the local store is a filtered
	// subset of the remote set). Nil-safe: a failed open just means rejects get
	// re-fetched and re-rejected each round.
	tombs, tombErr := tombstones.Open(fs, config.TombstonePath,
		time.Duration(config.SyncWindowDays+9)*24*time.Hour)
	if tombErr != nil {
		log.Println("⚠️ tombstone store unavailable (sync will re-fetch rejected events):", tombErr)
	} else {
		defer tombs.Close()
	}

	// Catch-up notifications are batched: a backlog import shouldn't fire
	// hundreds of system notifications. The live subscription below bypasses
	// this (notifier=nil ⇒ notify immediately).
	notifier := &batchNotifier{}

	// In-memory record of WoT/blacklist rejects, folded into the negentropy
	// vector so they aren't re-downloaded every round. Not persisted: a restart
	// clears it exactly when the WoT is rebuilt and rejects deserve re-checking.
	rejects := &tempRejects{}

	inboxStore := &inboxNegStore{
		inbox:    wdbInbox,
		chat:     wdbChat,
		tombs:    tombs,
		rejects:  rejects,
		notifier: notifier,
		advance:  func(ts nostr.Timestamp) { advance(&lastSeen, ts) },
	}
	outboxStore := &outboxNegStore{
		outbox:  wdbOutbox,
		tombs:   tombs,
		advance: func(ts nostr.Timestamp) { advance(&lastSeenOwner, ts) },
	}

	// inboxCatchup re-fetches tagged events (replies, reactions, zaps, reposts,
	// mentions, gift-wrap DMs) published since the inbox watermark. Fallback
	// path for relays without NIP-77.
	inboxCatchup := func(relayList []string) {
		since := nostr.Timestamp(lastSeen.Load() - 60) // 60s overlap to avoid boundary misses
		// Widen to cover backdated gift-wrap DMs on relays without NIP-77 (the
		// negentropy path already covers them with its wide window).
		if floor := nostr.Timestamp(time.Now().Add(-giftWrapBackdateSlack).Unix()); floor < since {
			since = floor
		}
		filter := nostr.Filter{
			Tags:  nostr.TagMap{"p": pTags},
			Since: &since,
		}
		log.Println("📢 inbox catch-up pull since", time.Unix(int64(since), 0).Format(time.RFC3339), "on", len(relayList), "relays")
		for ev := range pool.FetchMany(ctx, relayList, filter) {
			if ctx.Err() != nil {
				return
			}
			processInboxEvent(ctx, ev, wdbInbox, wdbChat, notifier, rejects)
			advance(&lastSeen, ev.CreatedAt)
		}
	}

	// ownerCatchup re-fetches the owner's own events (notes, profile, follow
	// list, reactions, reposts) published since the owner watermark — e.g. posts
	// made from another client under the same key — into the outbox DB.
	ownerCatchup := func(relayList []string) {
		since := nostr.Timestamp(lastSeenOwner.Load() - 60)
		filter := nostr.Filter{
			Authors: pTags,
			Since:   &since,
		}
		log.Println("📢 owner catch-up pull since", time.Unix(int64(since), 0).Format(time.RFC3339), "on", len(relayList), "relays")
		for ev := range pool.FetchMany(ctx, relayList, filter) {
			if ctx.Err() != nil {
				return
			}
			processOwnerEvent(ctx, ev, wdbOutbox)
			advance(&lastSeenOwner, ev.CreatedAt)
		}
	}

	// The negentropy reconciliation window. Wider than the watermark on
	// purpose: NIP-59 gift wraps randomize created_at up to 2 days into the
	// past, and a relay that was down during earlier pulls may hold events the
	// watermark has already moved past. ID-set reconciliation makes the wide
	// window cheap — already-known IDs transfer as fingerprints, not events.
	syncSince := func() nostr.Timestamp {
		return nostr.Timestamp(time.Now().Add(-time.Duration(config.SyncWindowDays+2) * 24 * time.Hour).Unix())
	}

	isSeedRelay := func(url string) bool {
		return slices.Contains(config.ImportSeedRelays, url) || (macBase != "" && url == macBase)
	}

	// runCatchup reconciles each relay via NIP-77 when supported, collecting
	// the rest for one watermark-based FetchMany pull. Sequential per relay to
	// keep mobile CPU/battery use flat.
	//
	// announce says whether this round may end in a "while you were away"
	// summary. Only the timer-driven rounds qualify: a round the user triggered
	// by refreshing is not a return from absence (see batchNotifier.flush).
	runCatchup := func(announce bool) {
		// Captured before any fetching so events arriving mid-round aren't
		// skipped: the fallback queries below re-query from lastSeen-60.
		roundStart := nostr.Timestamp(time.Now().Unix())
		// Re-check cached transient rejects against the live WoT/blacklist: an
		// author admitted since their event was rejected (the WoT is recomputed
		// on a 24h ticker) gets that event re-offered and imported this round,
		// instead of staying hidden behind a stub until process restart.
		rejects.reevaluate(func(pk string) bool {
			return !isBlacklisted(pk) && wot.GetInstance().Has(ctx, pk)
		})
		var fallback []string
		if config.NegentropySyncEnabled {
			since := syncSince()
			inboxFilter := nostr.Filter{Tags: nostr.TagMap{"p": pTags}, Since: &since}
			ownerFilter := nostr.Filter{Authors: pTags, Since: &since}
			// One vector per store per round, reused across relays: the build
			// materializes and JSON-decodes the whole windowed local set, which
			// dwarfs the per-relay reconciliation cost. Events downloaded from
			// an earlier relay this round aren't in the reused vector for later
			// ones — they get re-offered and deduped by the store, far cheaper
			// than a fresh full-store query per relay.
			inboxVec, ivErr := negsync.BuildVector(ctx, inboxStore, inboxFilter)
			var ownerVec *negsync.LocalVector
			if ivErr != nil {
				slog.Warn("negentropy inbox vector build failed, plain catch-up this round", "err", ivErr)
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
					rctx, cancel := context.WithTimeout(ctx, 90*time.Second)
					stats, err := negsync.SyncWithVector(rctx, inboxStore, inboxVec, url, inboxFilter, negsync.Down)
					if err == nil {
						markNegentropySupported(url)
						log.Printf("📥 negentropy inbox sync %s: %d new (local set %d)", url, stats.Downloaded, stats.LocalHave)
						// Owner sync (Both: heal gaps in both directions) only
						// against seed relays — DM relays reject public kinds.
						if isSeedRelay(url) {
							if ownerVec == nil {
								var ovErr error
								ownerVec, ovErr = negsync.BuildVector(rctx, outboxStore, ownerFilter)
								if ovErr != nil {
									slog.Warn("negentropy owner vector build failed, skipping owner sync this round", "err", ovErr)
								}
							}
							if ownerVec != nil {
								ostats, oerr := negsync.SyncWithVector(rctx, outboxStore, ownerVec, url, ownerFilter, negsync.Both, uploadMemoFor(url))
								if oerr == nil {
									log.Printf("📤 negentropy owner sync %s: %d down / %d up", url, ostats.Downloaded, ostats.Uploaded)
								} else {
									slog.Warn("negentropy owner sync failed", "relay", url, "err", oerr)
								}
							}
						}
					}
					cancel()
					switch {
					case err == nil:
					case errors.Is(err, negsync.ErrUnsupported):
						log.Println("ℹ️ no NIP-77 support, using plain catch-up for", url)
						markNegentropyUnsupported(url)
						fallback = append(fallback, url)
					case errors.Is(err, negsync.ErrRefused):
						// The refusal (e.g. "blocked: too many query results")
						// is deterministic for this filter — re-probing every
						// round hammers the relay into rate-limiting us (damus
						// 503s). Cache like unsupported for the retry TTL.
						slog.Warn("negentropy sync refused, plain catch-up until retry TTL", "relay", url, "err", err)
						markNegentropyUnsupported(url)
						fallback = append(fallback, url)
					default:
						slog.Warn("negentropy sync failed, plain catch-up this round", "relay", url, "err", err)
						fallback = append(fallback, url)
					}
				}
			}
		} else {
			fallback = relays
		}
		if len(fallback) > 0 && ctx.Err() == nil {
			inboxCatchup(fallback)
			ownerCatchup(fallback)
		}
		// Advance both watermarks to the start of this round regardless of
		// whether anything was written. The fallback catch-up queries start from
		// lastSeen-60; if the watermark only moved when an event was actually
		// saved (the old behavior), a quiet relay left `since` pinned in the past
		// and every cycle re-queried an ever-widening historical window —
		// expanding downloads and 100% CPU. advance() is monotonic, so this only
		// ever moves the watermarks forward.
		if ctx.Err() == nil {
			advance(&lastSeen, roundStart)
			advance(&lastSeenOwner, roundStart)
		}
		// Bound the temp-reject cache to the negentropy window so it can't grow
		// without limit over the process's lifetime (stubs older than the window
		// are never offered anyway).
		rejects.prune(syncSince())
		notifier.flush(announce)
		// A round materializes the full windowed local set per relay (the
		// negentropy vector build); hand the spike back to the OS instead of
		// letting darwin's lazy reclaim report it as resident until the next GC.
		debug.FreeOSMemory()
	}

	// Periodic + on-demand catch-up pull: reconcile anything missed while
	// disconnected (or beyond the live window). Driven by
	// INBOX_PULL_INTERVAL_SECONDS and by relaySyncCh (pull-to-refresh).
	pullEvery := config.InboxPullIntervalSeconds
	if pullEvery <= 0 {
		pullEvery = 3600
	}
	runsafe.Go("subscribeInboxAndChat.catchup", func() {
		ticker := time.NewTicker(time.Duration(pullEvery) * time.Second)
		defer ticker.Stop()
		var lastRun time.Time

		// Initial catch-up shortly after start (WoT is already ready here).
		// Without it the first reconciliation waits a full pull interval, so a
		// relay holding stale local data — e.g. an outdated follow list the
		// network has since superseded — keeps serving it for up to an hour
		// after every app launch.
		select {
		case <-ctx.Done():
			return
		case <-time.After(20 * time.Second):
		}
		// The first round after launch genuinely is a catch-up on whatever
		// arrived while the app was not running, so it may announce.
		runCatchup(true)
		lastRun = time.Now()

		// One-time full-history copy from the Mac relay, after the first round
		// so recent items land first. Runs on this goroutine so it never
		// overlaps a catch-up round on the same stores.
		macFill := &macBackfiller{
			pTags:      pTags,
			inboxNeg:   inboxStore,
			outboxNeg:  outboxStore,
			wdbInbox:   wdbInbox,
			wdbChat:    wdbChat,
			wdbOutbox:  wdbOutbox,
			notifier:   notifier,
			rejects:    rejects,
			now:        time.Now,
			negEnabled: config.NegentropySyncEnabled,
		}
		macFill.runIfNeeded(ctx, false)

		// A round that runs longer than the tick interval leaves a tick
		// pending, which would start the next round immediately — and once
		// the DBs are big enough that every round overruns, the loop
		// degenerates into back-to-back full-DB scans at 100% CPU with no
		// idle ever again. Restarting the ticker (after dropping any stale
		// tick) guarantees a full idle interval between rounds no matter how
		// long a round takes.
		restartTicker := func() {
			select {
			case <-ticker.C:
			default:
			}
			ticker.Reset(time.Duration(pullEvery) * time.Second)
		}
		restartTicker()

		for {
			announce := true
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			case <-relaySyncCh:
				// Throttle on-demand pulls: every sync round dials fresh
				// connections to every relay, so rapid pull-to-refresh must
				// not stack rounds and starve the clients' own sockets.
				if time.Since(lastRun) < minSyncGap {
					slog.Debug("relay sync request throttled", "since_last", time.Since(lastRun))
					continue
				}
				log.Println("📢 relay sync requested (pull-to-refresh)")
				// The user is looking at the app right now.
				announce = false
			case <-catchUpCh:
				// The app came back to the foreground or woke in the
				// background: a return from absence, so it may announce.
				if time.Since(lastRun) < minSyncGap {
					slog.Debug("catch-up request throttled", "since_last", time.Since(lastRun))
					continue
				}
				log.Println("📢 catch-up requested (app returned)")
			case <-macCheckCh:
				macFill.runIfNeeded(ctx, true)
				lastRun = time.Now()
				restartTicker()
				continue
			}
			runCatchup(announce)
			lastRun = time.Now()
			restartTicker()
		}
	})

	// Live subscription with reconnect. SubscribeMany's channel closes when the
	// context is cancelled or all relays send CLOSED; the previous code treated
	// that as terminal and never resubscribed. Now we reconnect (resuming from
	// lastSeen) with capped exponential backoff until the context is cancelled.
	log.Println("📢 subscribing to inbox on", len(relays), "relays (import + DM)")
	backoff := time.Second
	for ctx.Err() == nil {
		since := nostr.Timestamp(lastSeen.Load())
		filter := nostr.Filter{
			Tags:  nostr.TagMap{"p": pTags},
			Since: &since,
		}
		sawEvent := false
		for ev := range pool.SubscribeMany(ctx, relays, filter) {
			sawEvent = true
			processInboxEvent(ctx, ev, wdbInbox, wdbChat, nil, rejects)
			advance(&lastSeen, ev.CreatedAt)
		}
		if ctx.Err() != nil {
			return
		}
		if sawEvent {
			backoff = time.Second // healthy connection delivered events; reset
		}
		log.Println("📢 inbox subscription closed, reconnecting in", backoff)
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		if backoff < 60*time.Second {
			backoff *= 2
		}
	}
}

// rejectReason says why an inbox event was not accepted. The distinction
// matters for tombstoning: only rejections based on immutable event content
// (no whitelisted p-tag) may be recorded permanently. WoT and blacklist
// membership change over time — a fresh instance's half-built WoT rejecting a
// reply must NOT prevent that reply from importing on a later sync.
type rejectReason int

const (
	rejectNone rejectReason = iota
	rejectBlacklist
	rejectNotInWot
	rejectNoWhitelistedPTag
)

// permanent reports whether this rejection can never change for the event.
func (r rejectReason) permanent() bool { return r == rejectNoWhitelistedPTag }

// inboxClassification is the outcome of the inbox acceptance rules for one
// tagged event.
type inboxClassification struct {
	accept    bool
	reason    rejectReason // why not accepted (rejectNone when accept)
	chat      bool         // store in the chat DB (gift wraps) instead of the inbox DB
	notify    bool         // author isn't the tagged owner — warrants a notification
	recipient string       // hex pubkey of the whitelisted account this event is tagged for
}

// classifyInboxEvent applies the blacklist / Web-of-Trust / whitelisted-p-tag
// rules to a tagged event. Single source of truth shared by the live
// subscription, the watermark catch-up pull, and the negentropy sync path so
// their accept/reject behavior cannot drift.
func classifyInboxEvent(ctx context.Context, ev *nostr.Event) inboxClassification {
	if isBlacklisted(ev.PubKey) {
		slog.Debug("🚫discarding imported note from blacklisted pubkey", "pubkey", ev.PubKey, "id", ev.ID)
		return inboxClassification{reason: rejectBlacklist}
	}
	if !wot.GetInstance().Has(ctx, ev.PubKey) && ev.Kind != nostr.KindGiftWrap {
		return inboxClassification{reason: rejectNotInWot}
	}
	for tag := range ev.Tags.FindAll("p") {
		if len(tag) < 2 {
			continue
		}
		if _, ok := config.WhitelistedPubKeys[tag[1]]; !ok {
			continue
		}
		return inboxClassification{
			accept: true,
			chat:   ev.Kind == nostr.KindGiftWrap,
			// Skip notifying when the author is tagging themselves (e.g.
			// replying to their own note) — still imported, just not notified.
			notify:    ev.PubKey != tag[1],
			recipient: tag[1],
		}
	}
	return inboxClassification{reason: rejectNoWhitelistedPTag}
}

// logInboxImport prints the human-readable import line for a stored inbox/chat
// event. These exact phrases also drive the clients' relay-activity red dot.
func logInboxImport(ev *nostr.Event) {
	switch ev.Kind {
	case nostr.KindTextNote:
		log.Println("📰 new note in your inbox")
	case nostr.KindReaction:
		log.Println(ev.Content, "new reaction in your inbox")
	case nostr.KindZap:
		log.Println("⚡️ new zap in your inbox")
	case nostr.KindEncryptedDirectMessage:
		log.Println("🔒✉️ new encrypted message in your inbox")
	case nostr.KindGiftWrap:
		log.Println("🎁🔒️✉️ new gift-wrapped message in your chat relay")
	case nostr.KindRepost:
		log.Println("🔁 new repost in your inbox")
	case nostr.KindFollowList:
		// do nothing
	default:
		log.Println("📦 new event kind", ev.Kind, "event in your inbox")
	}
}

// processInboxEvent applies blacklist / Web-of-Trust / whitelist filtering to a
// tagged event and stores it in the inbox (or chat) DB if it passes. Shared by
// the live subscription and the periodic catch-up pull. When notifier is nil
// (live subscription) accepted events notify immediately; otherwise the
// notifier applies catch-up batch suppression.
func processInboxEvent(ctx context.Context, ev nostr.RelayEvent, wdbInbox, wdbChat eventstore.RelayWrapper, notifier *batchNotifier, rejects *tempRejects) {
	relayURL := ""
	if ev.Relay != nil {
		relayURL = ev.Relay.URL
	}
	c := classifyInboxEvent(ctx, ev.Event)
	if !c.accept {
		return
	}
	dbToPublish := wdbInbox
	if c.chat {
		dbToPublish = wdbChat
	}

	slog.Debug("ℹ️ importing event", "kind", ev.Kind, "id", ev.ID, "relay", relayURL)

	if isDuplicate(ctx, dbToPublish, ev.Event) {
		slog.Debug("ℹ️ skipping duplicate event", "id", ev.ID)
		return
	}

	if err := dbToPublish.Publish(ctx, *ev.Event); err != nil {
		log.Println("🚫 error importing tagged note", ev.ID, ":", "from relay", relayURL, ":", err)
		return
	}
	// If this event had a negentropy temp-reject stub (rejected earlier when its
	// author was outside the WoT), it's now stored for real — clear the stub so
	// inboxNegStore.QuerySync doesn't list it twice (DB + stub).
	rejects.remove(ev.ID)

	// Publish writes straight to the DB; khatru only notifies live REQ
	// subscriptions for events that arrive over its own websocket. Broadcast
	// so an open client (the app's Relay tab) sees the import immediately.
	liveRelay := inboxRelay
	if c.chat {
		liveRelay = chatRelay
	}
	if liveRelay != nil {
		liveRelay.BroadcastEvent(ev.Event)
	}

	// Emit a machine-parseable marker so clients can raise a local system
	// notification for this newly-imported inbox/chat event. Self-filters by
	// kind; the prose lines above are left intact for the relay-activity dot.
	// logInboxImport is gated on c.notify (not just c.accept above) so
	// self-tagged events (e.g. replying to your own note) don't light up the
	// red dot — they're still imported, just not "activity from someone else".
	// Also gated on isNotifyableAge so old backlog (e.g. a catch-up round that
	// only just succeeded after being stuck) doesn't light up the dot either —
	// notifier.maybeNotify already skipped its own emitInboxNotify call for
	// this, but previously still let logInboxImport through unconditionally.
	if c.notify && isNotifyableAge(ev.Event) {
		logInboxImport(ev.Event)
		if notifier != nil {
			notifier.maybeNotify(ev.Event, c.recipient)
		} else {
			emitInboxNotify(ev.Event, c.recipient)
		}
	}
}

// emitInboxNotify prints a single machine-parseable marker line for a newly
// imported inbox/chat event so clients (currently the Android app's LogStore)
// can raise a local system notification without a remote push server. Format:
//
//	🔔NOTIFY|type=<t>|kind=<k>|author=<hex>|id=<hex>|recipient=<hex>|preview=<text>
//
// `recipient` is the whitelisted account's hex pubkey this event was tagged
// for — the relay's inbox is shared across every whitelisted account on the
// device, so clients need this to apply the right account's notification
// isNotifyableAge reports whether ev is recent enough to notify about. Events
// older than NotifyMaxAgeHours are historical backlog, not something that just
// happened — an unrelated bug fix or a Mac relay reconnecting after a long gap
// can suddenly let days/weeks of previously-stuck backlog through, and firing
// a live notification (red dot + sound) for each one reads as noise, not news.
// A zero/negative NotifyMaxAgeHours disables the check entirely.
// isNotifyableKind reports whether the host app wants notifications for this
// event kind. An empty NotifyKinds set means the app expressed no preference
// (or predates the setting) and every notifiable kind qualifies.
//
// This gate is what keeps the catch-up summary honest: the client can drop an
// individual marker for a kind the user switched off, but "N more new items"
// is a single number, so a kind counted here can never be filtered out later.
func isNotifyableKind(kind int) bool {
	if len(config.NotifyKinds) == 0 {
		return true
	}
	_, ok := config.NotifyKinds[kind]
	return ok
}

func isNotifyableAge(ev *nostr.Event) bool {
	maxAge := time.Duration(config.NotifyMaxAgeHours) * time.Hour
	return maxAge <= 0 || time.Since(ev.CreatedAt.Time()) <= maxAge
}

// preferences and to switch to the right account on tap, instead of guessing
// from whichever account happens to be active in the UI.
// `preview` is always the LAST field (it may contain spaces) and is empty for
// encrypted/opaque kinds (DMs, gift wraps, zaps). Self-filters by kind: kinds
// that should not notify (e.g. follow lists) produce no line.
func emitInboxNotify(ev *nostr.Event, recipient string) {
	if ev == nil {
		return
	}
	if !isNotifyableKind(ev.Kind) {
		return
	}
	var typ, preview string
	switch ev.Kind {
	case nostr.KindTextNote:
		typ = "mention"
		for _, tag := range ev.Tags {
			if len(tag) >= 1 && tag[0] == "e" {
				typ = "reply" // an "e" tag means this note replies to another
				break
			}
		}
		preview = sanitizeNotifyPreview(ev.Content)
	case nostr.KindReaction:
		typ = "reaction"
		preview = sanitizeNotifyPreview(ev.Content)
	case nostr.KindRepost:
		typ = "repost"
	case nostr.KindZap:
		typ = "zap"
	case nostr.KindEncryptedDirectMessage:
		typ = "dm"
	case nostr.KindGiftWrap:
		typ = "giftwrap"
	default:
		return // follow lists and anything else: no notification
	}
	log.Printf("🔔NOTIFY|type=%s|kind=%d|author=%s|id=%s|recipient=%s|preview=%s", typ, ev.Kind, ev.PubKey, ev.ID, recipient, preview)
}

// sanitizeNotifyPreview collapses newlines and trims a content string to a short
// single-line preview safe to embed in a NOTIFY marker line.
func sanitizeNotifyPreview(s string) string {
	s = strings.ReplaceAll(s, "\r", " ")
	s = strings.ReplaceAll(s, "\n", " ")
	s = strings.TrimSpace(s)
	if r := []rune(s); len(r) > 140 {
		s = string(r[:140]) + "…"
	}
	return s
}

// processOwnerEvent stores an owner-authored event into the outbox DB if it is
// from a whitelisted key and not already present. Used by the owner catch-up
// pull to surface notes the owner published from another client.
func processOwnerEvent(ctx context.Context, ev nostr.RelayEvent, wdbOutbox eventstore.RelayWrapper) {
	if _, ok := config.WhitelistedPubKeys[ev.PubKey]; !ok {
		return // relay returned a non-owner event; ignore
	}
	if isBlacklisted(ev.PubKey) {
		return
	}
	if isDuplicate(ctx, wdbOutbox, ev.Event) {
		return
	}
	if err := wdbOutbox.Publish(ctx, *ev.Event); err != nil {
		log.Println("🚫 error importing owner event", ev.ID, ":", err)
		return
	}
	// See processInboxEvent: wake live REQ subscriptions, which a direct DB
	// write bypasses.
	if outboxRelay != nil {
		outboxRelay.BroadcastEvent(ev.Event)
	}
	slog.Debug("📤 imported owner event", "kind", ev.Kind, "id", ev.ID)
}

// relaySyncCh signals the catch-up loop to pull immediately (e.g. from
// pull-to-refresh). Buffered + coalesced so a request made while a pull is
// already pending is not lost and does not stack up.
var relaySyncCh = make(chan struct{}, 1)

// RequestRelaySync triggers an immediate inbox + owner catch-up pull and a
// feed-cache sync round if the relay is running. Non-blocking; coalesces with
// any already-pending request. Safe to call when no relay is running (the
// signals are simply consumed by the next catch-up goroutines, or dropped).
func RequestRelaySync() {
	select {
	case relaySyncCh <- struct{}{}:
	default:
	}
	select {
	case feedSyncCh <- struct{}{}:
	default:
	}
}

// catchUpCh is relaySyncCh for a return from absence (app foregrounded, or a
// background wake): the round may end in a "while you were away" summary.
var catchUpCh = make(chan struct{}, 1)

// RequestCatchUp triggers an announcing catch-up round. Non-blocking,
// coalesced, and throttled like RequestRelaySync.
func RequestCatchUp() {
	select {
	case catchUpCh <- struct{}{}:
	default:
	}
}

// macCheckCh asks the catch-up loop to re-run the Mac relay full-history copy
// and its missing-events check.
var macCheckCh = make(chan struct{}, 1)

// RequestMacSyncCheck re-runs the Mac relay copy and check. Non-blocking,
// coalesced; a no-op when no Mac relay is configured.
func RequestMacSyncCheck() {
	select {
	case macCheckCh <- struct{}{}:
	default:
	}
}

func isDuplicate(ctx context.Context, db eventstore.RelayWrapper, event *nostr.Event) bool {
	filter := nostr.Filter{
		IDs:   []string{event.ID},
		Since: &event.CreatedAt,
		Limit: 1,
	}

	events, err := db.QuerySync(ctx, filter)
	if err != nil {
		log.Println("🚫 error querying for event", event.ID, ":", err)
		return false
	}

	return len(events) > 0
}
