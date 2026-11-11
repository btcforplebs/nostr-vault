import Foundation
import Combine
import SwiftUI

extension FeedService {
    /// Cold-launch entry point used by FeedView when the feed first appears with
    /// no notes. Restores the cached feed instantly when a disk snapshot exists,
    /// then streams newer notes on top via `topUpFromRelays()` (preserves scroll
    /// position and shows the inline "Syncing…" pill). Falls back to a full cold
    /// `refresh()` on first-ever launch or when no snapshot is available.
    func startInitialLoad() {
        didStartInitialLoad = true
        if feedMode.isLocalDvm {
            // The last result saved shows at once; loadLocalDvmFeed keeps it
            // up while the new one is computed.
            _ = restoreModeCache(for: feedMode)
            recomputeFilteredNotes()
            refresh()
            return
        }
        if didRestoreCachedFeed || restoreFromDiskIfAvailable() {
            didRestoreCachedFeed = true
            topUpFromRelays()
        } else {
            refresh()
        }
    }

    /// Snapshot the old account, restore (or cold-load) the new account, then
    /// kick off a relay top-up against the now-current state.
    func handleAccountSwitch() {
        let previousKey = loadedSnapshotNpub
        let newKey = currentSnapshotKey()
        guard previousKey != newKey else { return }

        // 1. Stash the just-rendered state under the previous npub.
        captureSnapshot(forKey: previousKey)
        // Write its likes now: a throttled save still waiting would run under
        // the new account's key. Reactions still being signed are dropped.
        writeInteractionState()
        pendingReactionTokens.removeAll()
        // Whether the web is complete is the previous account's answer.
        underratedEmptyReason = nil

        // 2. Only disconnect feed clients if we need a full refresh (no snapshot available).
        // This prevents unnecessary relay disconnections when switching between accounts
        // that have cached state. We'll disconnect later if needed during refresh().
        let hasSnapshot = accountSnapshots[newKey] != nil || diskSnapshotExists(forKey: newKey)
        if !hasSnapshot {
            // No snapshot — will need fresh data, so disconnect now.
            disconnectFeedClients()
        } else {
            // Kept sockets stop streaming the previous account's feed.
            closeFeedSubscriptions()
        }
        // The previous account's late frames on a kept socket carry the old
        // ids and are dropped, so they can't land in this account's feed or
        // its tab cache (Tron, #1547 follow-up).
        beginFeedSubGeneration()
        // NOTE: Global services (profile + Kind 10002 fetches) keep their clients
        // running across account switches by design.

        // 3. Cancel in-flight loading flags + timers so the new flow isn't blocked.
        // Each @Published write sends a change notice even when the value is
        // the same, and every one redraws the whole feed: only write a flag
        // that actually changes (iPad account switch, Tim 11-04: ~27 ms each).
        if isLoadingContacts { isLoadingContacts = false }
        // The new account's list is unknown until its own load answers, and a
        // tap queued under the previous account must not reach this one.
        if contactListConfirmed { contactListConfirmed = false }
        pendingFollowActions.removeAll()
        if FollowNotificationManager.shared.notifications.contains(where: { $0.pubkey != nil }) {
            FollowNotificationManager.shared.clearPending()
        }
        if isLoadingExtendedNetwork { isLoadingExtendedNetwork = false }
        // A local DVM feed computing for the previous account lands for
        // nobody (loadLocalDvmFeed); the new account's own load may start.
        if !loadingDvmFeeds.isEmpty { loadingDvmFeeds.removeAll() }
        extendedNetworkComputedAt = nil
        if isLoadingFeed { isLoadingFeed = false }
        if isSyncing { isSyncing = false }
        contactLoadingTimeout?.invalidate()
        feedLoadingTimeout?.invalidate()
        extendedNetworkTimeout?.invalidate()
        cancellables.removeAll()
        // A warm account switch keeps feed clients connected (no disconnect), so
        // clear the previous account's author-set bookkeeping explicitly here —
        // otherwise a reconcile could see a "matching" stale set and skip the
        // resubscribe the new account needs.
        subscribedAuthorsByRelay.removeAll()
        // The removeAll() above just orphaned every surviving feed client's sink
        // (see subscribedClientKeys) — clear so subscribeToAllRelays() knows to
        // re-establish them instead of silently dropping this account's events.
        subscribedClientKeys.removeAll()
        contactRetryScheduled = false

        // 4. Either restore an in-memory snapshot OR cold-load.
        //    Wrapped in withAnimation so SwiftUI cross-fades the content
        //    transition instead of hard-cutting between accounts.
        var restored = false
        didStartInitialLoad = true
        didRestoreCachedFeed = false
        withAnimation(Motion.fade) {
            loadedSnapshotNpub = newKey
            restored = restoreSnapshot(forKey: newKey)
            if !restored {
                // No in-memory snapshot — fall back to the on-disk snapshot
                // (faster than a full cold load).
                restored = applyDiskSnapshot(forKey: newKey)
            }
            if !restored {
                // No cached feed — load persisted interaction state for this
                // account from disk so likes/zaps appear correctly even on first
                // visit after launch.
                clearInMemoryFeedState()
                loadInteractionState(forKey: newKey)
            }
            newNoteCount = 0
            newSinceLastView = Date()
            didRestoreCachedFeed = restored
        }

        // 5. Kick off relay traffic.
        if feedMode.isLocalDvm {
            // Local DVM feeds are ephemeral — always re-fetch on account switch.
            loadLocalDvmFeed()
        } else if restored {
            // Block follow/unfollow until the relay re-fetch completes,
            // so we don't publish the stale snapshot contact list.
            isLoadingContacts = true
            // Background top-up: subscribe to relays but keep the cached feed
            // visible. The inline syncing pill replaces the full-screen spinner.
            topUpFromRelays()
        } else if isGlobalLikeMode {
            shouldScrollToTopOnLoad = true
            loadWotPubkeys()
            subscribeToAllRelays()
        } else {
            // Attempt to seed the follow set from FollowingBackupService's
            // persisted snapshots before falling back to a full cold load.
            // This turns most "cold" loads into warm loads — the feed subscribes
            // to relays immediately with the seed pubkeys and refreshes the
            // contact list in the background, just like topUpFromRelays().
            let backupService = FollowingBackupService.shared
            backupService.loadSnapshots(forAccountKey: newKey)

            if let latest = backupService.snapshots.last, !latest.pubkeys.isEmpty {
                contactListPTags = latest.pTags
                followedPubkeys = latest.pubkeys
                contactListContent = latest.contactListContent
                lastFetchedContactCount = latest.pubkeys.count
                isLoadingContacts = true

                if feedMode == .discovery {
                    // Discovery needs extended network before subscribing.
                    // Compute it from the seed contacts, then subscribe.
                    // Refresh the authoritative contact list in parallel.
                    isSyncing = true
                    loadExtendedNetwork { [weak self] in
                        self?.subscribeToAllRelays()
                    }
                    loadContactList { [weak self] in
                        self?.isSyncing = false
                    }
                } else {
                    topUpFromRelays()
                }
            } else {
                // No backup available — true cold start.
                refresh()
            }
        }
    }

    // MARK: - Public API

    /// refresh(), or, while contacts are loading (refresh() refuses then),
    /// once they finish. For a re-ask that nothing would repeat if dropped.
    func refreshAfterContactLoad() {
        if isLoadingContacts { refreshQueuedForMode = feedMode } else { refresh() }
    }

    func refresh() {
        guard !isLoadingContacts, !isPaused else { return }
        // Music has no relay feed to reload; Hashtags reloads its own.
        if feedMode == .music || feedMode == .hashtags { return }

        // Ask the embedded relay to catch up its inbox/outbox from external
        // relays too, so a feed pull-to-refresh also freshens the Relay tab,
        // DMs, and notifications. Non-blocking, coalesced, no-op-safe when the
        // relay isn't running.
        if RelayProcessManager.shared.isRunning && !RelayProcessManager.shared.isBooting {
            RequestRelaySyncC()
        }

        if feedMode.isLocalDvm {
            loadLocalDvmFeed()
            return
        }
        // Global's thread replies were fetched under the old list and trust
        // setting; Threaded View fetches them again for the reloaded posts.
        if feedMode == .global { resetFeedThreadReplies() }

        #if DEBUG
        print("FeedService: [refresh] start — followedPubkeys=\(followedPubkeys.count) notes=\(notes.count) filtered=\(filteredNotes.count)")
        #endif

        disconnectFeedClients()
        shouldScrollToTopOnLoad = true
        newNoteCount = 0
        newSinceLastView = Date()
        lastEventTimestamp = 0

        loadContactList { [weak self] in
            guard let self = self else { return }

            // Route a genuinely new Nostr user — no follows AND no local
            // following backup to seed from — to the curated Global feed.
            // Returning users whose contact fetch was merely slow/empty were
            // already seeded from backup by handleContactLoadResolved()
            // (seed-and-stay), so their followedPubkeys is non-empty here and
            // they stay on Following.
            //
            // This used to send them to Popular, which ranks raw engagement
            // from open relays: measured on the shipped seed relays, two thirds
            // of that traffic was one spam campaign, and it was the first thing
            // a new user ever saw. Global is now filtered by a trust graph the
            // relay seeds from the starter pack, and it fails closed while that
            // graph is still being built. Popular remains available as an
            // explicit choice in the feed menu.
            //
            // Nothing here publishes a contact list — the user's follows stay
            // empty until they choose to follow someone.
            let hasBackup = !(FollowingBackupService.shared.snapshots.last?.pubkeys.isEmpty ?? true)
            if self.followedPubkeys.isEmpty && self.isFollowSetMode && !hasBackup
                && !InterestListService.shared.hashtags.isEmpty {
                // Topics picked (the Fill your feed guide) but nobody followed
                // yet: their topic feed is where they find people, and it
                // stays put when they follow someone.
                self.switchMode(.hashtags)
                return
            }
            if self.followedPubkeys.isEmpty && self.isFollowSetMode && !hasBackup {
                self.didAutoSwitchToCurated = true
                self.feedMode = .global
                self.loadWotPubkeys()
                self.recomputeFilteredNotes()
                self.pollForCuratedGraph()
                self.subscribeToAllRelays()
                return
            }

            if self.feedMode == .discovery {
                self.loadExtendedNetwork { [weak self] in
                    self?.subscribeToAllRelays()
                }
            } else {
                self.subscribeToAllRelays()
            }
        }
    }

    func switchMode(_ mode: FeedMode) {
        guard mode != feedMode else { return }
        // Picking a feed is a choice to stay on it: the first follow no
        // longer pulls a new account from its topic feed back to Following.
        didAutoSwitchToCurated = false
        let previous = feedMode
        // Side feeds linger connected for a minute (see sideFeedLinger).
        scheduleSideFeedDisconnect(previous)
        sideFeedDisconnects[mode]?.cancel()
        sideFeedDisconnects[mode] = nil
        // Keep what this feed showed, for a quick switch back.
        captureModeCache(for: previous)
        shouldScrollToTopOnLoad = true
        feedMode = mode
        notes.removeAll()
        resetFeedThreadReplies()
        parentNotesCache.removeAll()
        parentNotesCacheTrimAt = 500
        processingQueue.async { [bgAccumulator] in bgAccumulator.resetParentFetchClaims() }
        pendingNotes.removeAll()
        noteBuffer.removeAll()
        seenIds.removeAll()
        fetchingNoteIds.removeAll()
        fetchingNoteTimestamps.removeAll()
        noteFetchQueue.removeAll()
        noteFetchTimer?.invalidate()
        noteFetchTimer = nil
        noteFetchPasses.removeAll()
        unavailableNoteIds.removeAll()
        noteStats.removeAll()
        popularNoteScores.removeAll()
        newNoteCount = 0
        newSinceLastView = Date()
        lastEventTimestamp = 0
        isSyncing = false
        let cachedAge = Self.usesNotePipeline(mode) ? restoreModeCache(for: mode) : nil
        recomputeFilteredNotes()
        // Between two relay-streamed feeds the open sockets stay: the next
        // subscribe re-sends each one the new REQ, which replaces the old
        // subscription (one id per relay). Closing and reopening every socket
        // on every switch was the slow part. Anything else closes them.
        if FeedSpeedPolicy.keepsFeedSockets(fromStreams: Self.streamsFromRelays(previous),
                                            toStreams: Self.streamsFromRelays(mode)) {
            detachFeedClients()
            closeFeedSubscriptions()
        } else {
            disconnectFeedClients()
        }
        beginFeedSubGeneration()
        cancellables.removeAll()

        // Reset global mode flag when switching away from global
        let isGlobal = mode == .global
            || (mode == .media && mediaFeedMode == .global)
            || (mode == .articles && articlesFeedMode == .global)
            || (mode == .polls && pollsFeedMode == .global)
        processingQueue.async { [weak self] in
            self?.bgAccumulator.isGlobalMode = isGlobal
        }

        if mode == .music {
            // Wavlake, not relays: MusicBrowserView loads its own catalogue,
            // and the note pipeline stays idle underneath it.
        } else if mode == .hashtags {
            // HashtagsFeedSection queries relays for its tags itself.
        } else if mode == .live {
            // Same reasoning as Recipes: LiveFeedService owns this one.
            LiveFeedService.shared.loadIfNeeded()
        } else if mode == .reels {
            // ReelsFeedService runs its own queries; the note pipeline would
            // only stream a timeline nobody sees underneath the videos.
            ReelsFeedService.shared.loadIfNeeded()
        } else if mode == .recipes {
            // Recipes are served by RecipeFeedService against external relays —
            // the note pipeline has nothing to subscribe to here, and starting
            // it would open follow-set subscriptions nothing will read.
            RecipeFeedService.shared.loadIfNeeded()
        } else if mode == .marketplace {
            // Same as Recipes: MarketplaceFeedService queries listing relays
            // itself, so the note pipeline stays idle underneath the grid.
            MarketplaceFeedService.shared.loadIfNeeded()
        } else if mode.isLocalDvm {
            // Computed, not streamed: a recent result is shown as it was.
            if let cachedAge, cachedAge < Self.popularCacheFreshFor {
                connectionStatus = "Live"
            } else {
                loadLocalDvmFeed()
            }
        } else if cachedAge != nil {
            // Back to a feed seen minutes ago: its notes are already on screen,
            // so only ask relays for what is newer (subscriptions resume from
            // the restored lastEventTimestamp).
            shouldScrollToTopOnLoad = false
            if mode == .discovery && extendedNetworkPubkeys.isEmpty {
                // Discover restored from disk before its network was known:
                // the saved notes stay up while the network is walked.
                loadExtendedNetwork { [weak self] in self?.subscribeToAllRelays() }
            } else {
                topUpFromRelays()
            }
        } else if isGlobal {
            // Global mode doesn't need contacts — subscribe directly
            loadWotPubkeys()
            pollForCuratedGraph()
            subscribeToAllRelays()
        } else {
            refresh()
        }
    }

    /// Discard the cached snapshot for the current account and run a full
    /// cold reload. Use sparingly — the normal account-switch path already
    /// restores instantly from the in-memory snapshot.
    func forceReload() {
        accountSnapshots.removeValue(forKey: loadedSnapshotNpub)
        clearInMemoryFeedState()
        shouldScrollToTopOnLoad = true
        newNoteCount = 0
        newSinceLastView = Date()
        isLoadingContacts = false
        isLoadingFeed = false
        isLoadingExtendedNetwork = false
        isSyncing = false
        contactLoadingTimeout?.invalidate()
        feedLoadingTimeout?.invalidate()
        extendedNetworkTimeout?.invalidate()
        disconnectFeedClients()
        cancellables.removeAll()

        if feedMode == .reels {
            ReelsFeedService.shared.refresh()
        } else if feedMode.isLocalDvm {
            loadLocalDvmFeed()
        } else if isGlobalLikeMode {
            loadWotPubkeys()
            subscribeToAllRelays()
        } else {
            refresh()
        }
    }

    /// Close only the feed-level WebSocket connections. The
    /// `NostrService.clients` pool is left alone so profile and Kind-10002
    /// lookups carry over across account switches.
    /// The feeds whose notes stream from relay subscriptions through this
    /// service's pipeline (Popular is computed, side feeds run their own).
    static func streamsFromRelays(_ mode: FeedMode) -> Bool {
        usesNotePipeline(mode) && !mode.isLocalDvm
    }

    /// Keeps the feed sockets open but drops this service's ties to them:
    /// their sinks go with `cancellables`, and the next subscribe attaches new
    /// ones and re-sends the REQ (see `subscribeToAllRelays`). One-shot page
    /// clients belong to the old feed and are closed, and so is any socket
    /// not connected yet: its connect sink is gone, so it would open and
    /// never be sent a REQ.
    private func detachFeedClients() {
        for (key, client) in feedClients where key.hasPrefix("page-") || client.connectionState != .connected {
            client.disconnect()
            feedClients.removeValue(forKey: key)
            relayStateSinks.removeValue(forKey: key)
            relayStates.removeValue(forKey: Self.relayStateKey(key))
        }
        subscribedAuthorsByRelay.removeAll()
        subscribedClientKeys.removeAll()
        contactRetryScheduled = false
    }

    /// Factory reset: the feed and follow list on screen, every account's
    /// snapshot in memory and the follow backups go, and nothing is keyed
    /// until an account is set up, so no running save writes the old
    /// account's feed back after its files were deleted. The old feed's
    /// subscriptions are closed and their late frames dropped, so its notes
    /// can't land in the next account's feed.
    func forgetForFactoryReset() {
        closeFeedSubscriptions()
        beginFeedSubGeneration()
        clearInMemoryFeedState()
        accountSnapshots.removeAll()
        modeCaches.removeAll()
        loadedSnapshotNpub = ""
        didRestoreCachedFeed = false
        FollowingBackupService.shared.forgetAll()
    }

    /// New feed subscription ids from here on, for a tab or account switch.
    /// Frames for the old ones are dropped on processingQueue, which runs this
    /// before any new sink's (FeedSpeedPolicy.isStaleFeedSub).
    func beginFeedSubGeneration() {
        feedSubGeneration = FeedSpeedPolicy.nextFeedSubGeneration(after: feedSubGeneration)
        let generation = feedSubGeneration
        processingQueue.async { [bgAccumulator] in bgAccumulator.feedSubGeneration = generation }
    }

    /// Sends CLOSE for every subscription the old feed opened on the sockets
    /// kept across a switch, so relays stop streaming it.
    private func closeFeedSubscriptions() {
        for (key, client) in feedClients where !key.hasPrefix("page-") {
            for subId in FeedSpeedPolicy.feedSubIds(generation: feedSubGeneration, relaySuffix: Self.feedSubSuffix(key)) {
                if let data = try? JSONSerialization.data(withJSONObject: ["CLOSE", subId]),
                   let text = String(data: data, encoding: .utf8) {
                    client.send(text: text)
                }
            }
        }
    }

    private func disconnectFeedClients() {
        feedClients.values.forEach { $0.disconnect() }
        feedClients.removeAll()
        relayStateSinks.removeAll()
        relayStates.removeAll()
        // No live subscriptions remain — drop the author-set bookkeeping so a
        // later reconcile doesn't think a relay is still subscribed.
        subscribedAuthorsByRelay.removeAll()
        subscribedClientKeys.removeAll()
        contactRetryScheduled = false
    }

    /// Disconnect feed relay clients and stop timers to reduce background
    /// resource usage. Call `resumeFeed()` to reconnect when the feed is
    /// visible again. Notes already in memory are preserved.
    func pauseFeed() {
        guard !isPaused else { return }
        isPaused = true
        disconnectFeedClients()
        disconnectInjectionClients()
        cancellables.removeAll()
        noteFlushTimer?.invalidate()
        noteFlushTimer = nil
        noteFetchTimer?.invalidate()
        noteFetchTimer = nil
        feedLoadingTimeout?.invalidate()
        feedLoadingTimeout = nil
        isLoadingFeed = false
        isSyncing = false
        #if DEBUG
        print("FeedService: paused — relay clients disconnected")
        #endif
    }

    /// Reconnect to relays after a `pauseFeed()`. Only subscribes if we
    /// already have contacts loaded so we don't kick off a full cold start.
    func resumeFeed() {
        guard isPaused else { return }
        isPaused = false
        #if DEBUG
        print("FeedService: resuming — reconnecting relay clients")
        #endif
        if feedMode.isLocalDvm {
            // Local DVM feeds don't use relay subscriptions — re-fetch if stale
            if notes.isEmpty { loadLocalDvmFeed() }
        } else {
            // Route through the idempotent reconciler so resume reconnects the
            // right relay set and (re)subscribes with the current follow set —
            // and self-heals contacts if the follow set is somehow empty.
            reconcileFeedSubscriptions()
        }
    }

    func disconnect() {
        feedLoadingTimeout?.invalidate()
        contactLoadingTimeout?.invalidate()
        disconnectFeedClients()
        cancellables.removeAll()
        connectionStatus = "Disconnected"
        isSyncing = false
    }
}
