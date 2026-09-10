package main

import (
	"context"
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

	"github.com/barrydeen/haven/pkg/runsafe"
	"github.com/barrydeen/haven/pkg/wot"
)

const layout = "2006-01-02"

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
	)

	// Try to load from cache first. MarkReady on the cache-hit path also
	// stores the instance, so GetInstance() below never returns nil.
	gate := wot.NewCycle()
	if wotModel.LoadFromCache() {
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
					if _, ok := config.BlacklistedPubKeys[ev.PubKey]; ok {
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

				if _, ok := config.BlacklistedPubKeys[ev.PubKey]; ok {
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

	// inboxCatchup re-fetches tagged events (replies, reactions, zaps, reposts,
	// mentions, gift-wrap DMs) published since the inbox watermark.
	inboxCatchup := func() {
		since := nostr.Timestamp(lastSeen.Load() - 60) // 60s overlap to avoid boundary misses
		filter := nostr.Filter{
			Tags:  nostr.TagMap{"p": pTags},
			Since: &since,
		}
		log.Println("📢 inbox catch-up pull since", time.Unix(int64(since), 0).Format(time.RFC3339))
		for ev := range pool.FetchMany(ctx, relays, filter) {
			if ctx.Err() != nil {
				return
			}
			processInboxEvent(ctx, ev, wdbInbox, wdbChat)
			advance(&lastSeen, ev.CreatedAt)
		}
	}

	// ownerCatchup re-fetches the owner's own events (notes, profile, follow
	// list, reactions, reposts) published since the owner watermark — e.g. posts
	// made from another client under the same key — into the outbox DB.
	ownerCatchup := func() {
		since := nostr.Timestamp(lastSeenOwner.Load() - 60)
		filter := nostr.Filter{
			Authors: pTags,
			Since:   &since,
		}
		log.Println("📢 owner catch-up pull since", time.Unix(int64(since), 0).Format(time.RFC3339))
		for ev := range pool.FetchMany(ctx, relays, filter) {
			if ctx.Err() != nil {
				return
			}
			processOwnerEvent(ctx, ev, wdbOutbox)
			advance(&lastSeenOwner, ev.CreatedAt)
		}
	}

	// Periodic + on-demand catch-up pull: re-fetch anything published since the
	// watermarks so events missed while disconnected (or beyond the live window)
	// are pulled in. Driven by INBOX_PULL_INTERVAL_SECONDS (previously loaded but
	// never referenced) and by relaySyncCh (pull-to-refresh).
	pullEvery := config.InboxPullIntervalSeconds
	if pullEvery <= 0 {
		pullEvery = 3600
	}
	runsafe.Go("subscribeInboxAndChat.catchup", func() {
		ticker := time.NewTicker(time.Duration(pullEvery) * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			case <-relaySyncCh:
				log.Println("📢 relay sync requested (pull-to-refresh)")
			}
			inboxCatchup()
			ownerCatchup()
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
			processInboxEvent(ctx, ev, wdbInbox, wdbChat)
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

// processInboxEvent applies blacklist / Web-of-Trust / whitelist filtering to a
// tagged event and stores it in the inbox (or chat) DB if it passes. Shared by
// the live subscription and the periodic catch-up pull.
func processInboxEvent(ctx context.Context, ev nostr.RelayEvent, wdbInbox, wdbChat eventstore.RelayWrapper) {
	relayURL := ""
	if ev.Relay != nil {
		relayURL = ev.Relay.URL
	}
	if _, ok := config.BlacklistedPubKeys[ev.PubKey]; ok {
		slog.Debug("🚫discarding imported note from blacklisted pubkey", "pubkey", ev.PubKey, "id", ev.ID)
		return
	}
	if !wot.GetInstance().Has(ctx, ev.PubKey) && ev.Kind != nostr.KindGiftWrap {
		return
	}
	for tag := range ev.Tags.FindAll("p") {
		if len(tag) < 2 {
			continue
		}
		if _, ok := config.WhitelistedPubKeys[tag[1]]; !ok {
			continue
		}
		dbToPublish := wdbInbox
		if ev.Kind == nostr.KindGiftWrap {
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

		// Emit a machine-parseable marker so clients can raise a local system
		// notification for this newly-imported inbox/chat event. Self-filters by
		// kind; the prose lines above are left intact for the relay-activity dot.
		emitInboxNotify(ev.Event)
		return
	}
}

// emitInboxNotify prints a single machine-parseable marker line for a newly
// imported inbox/chat event so clients (currently the Android app's LogStore)
// can raise a local system notification without a remote push server. Format:
//
//	🔔NOTIFY|type=<t>|kind=<k>|author=<hex>|id=<hex>|preview=<text>
//
// `preview` is always the LAST field (it may contain spaces) and is empty for
// encrypted/opaque kinds (DMs, gift wraps, zaps). Self-filters by kind: kinds
// that should not notify (e.g. follow lists) produce no line.
func emitInboxNotify(ev *nostr.Event) {
	if ev == nil {
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
	log.Printf("🔔NOTIFY|type=%s|kind=%d|author=%s|id=%s|preview=%s", typ, ev.Kind, ev.PubKey, ev.ID, preview)
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
	if _, ok := config.BlacklistedPubKeys[ev.PubKey]; ok {
		return
	}
	if isDuplicate(ctx, wdbOutbox, ev.Event) {
		return
	}
	if err := wdbOutbox.Publish(ctx, *ev.Event); err != nil {
		log.Println("🚫 error importing owner event", ev.ID, ":", err)
		return
	}
	slog.Debug("📤 imported owner event", "kind", ev.Kind, "id", ev.ID)
}

// relaySyncCh signals the catch-up loop to pull immediately (e.g. from
// pull-to-refresh). Buffered + coalesced so a request made while a pull is
// already pending is not lost and does not stack up.
var relaySyncCh = make(chan struct{}, 1)

// RequestRelaySync triggers an immediate inbox + owner catch-up pull if the
// relay is running. Non-blocking; coalesces with any already-pending request.
// Safe to call when no relay is running (the signal is simply consumed by the
// next catch-up goroutine, or dropped).
func RequestRelaySync() {
	select {
	case relaySyncCh <- struct{}{}:
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
