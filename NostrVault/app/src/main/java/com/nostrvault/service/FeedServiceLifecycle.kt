package com.nostrvault.service

import com.nostrvault.data.model.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import android.util.Log
import com.nostrvault.BuildConfig
import com.nostrvault.service.FeedService.Companion.TAG
import com.nostrvault.service.FeedService.Companion.OUTBOX_RELAY_LIST_SETTLE_MS

    fun FeedService.disconnect() {
        teardownAllFeedClients()
        _connectionStatus.value = "Disconnected"
        _connectionColor.value = "gray"
    }

    /**
     * Cold-launch entry point.
     * Restores disk snapshot if available, then tops up from relays.
     */
    /**
     * Restores the cached feed at launch, before the relay is ready. iOS
     * `prewarmFromCache`: the disk snapshot is a local read, and holding it
     * back until the relay reports ready made every launch flash an empty
     * feed. Subscribing is still [startInitialLoadImpl]'s job.
     */
    internal fun FeedService.prewarmFromCacheImpl() {
        if (!shouldPrewarm(_feedMode.value, _notes.value.isEmpty(), cachedFeedRestored, initialLoadStarted)) return
        if (prewarmJob?.isActive == true) return
        prewarmJob = scope.launch {
            if (restoreFromDiskIfAvailable()) cachedFeedRestored = true
            if (BuildConfig.DEBUG) Log.d(TAG, "prewarmFromCache: restored=$cachedFeedRestored, notes=${_notes.value.size}")
        }
    }

    internal fun FeedService.startInitialLoadImpl() {
        if (BuildConfig.DEBUG) Log.d(TAG, "startInitialLoad: mode=${_feedMode.value}")
        initialLoadStarted = true

        // Pre-load WOT pubkeys so DISCOVERY and GLOBAL media modes work immediately
        loadWotPubkeys()

        if (_feedMode.value == FeedMode.POPULAR) {
            loadPopularFeed()
            return
        }

        scope.launch {
            // A prewarm still reading the snapshot finishes first, so it is
            // never applied twice; one that restored it means top up only.
            prewarmJob?.join()
            val restored = cachedFeedRestored || restoreFromDiskIfAvailable()
            if (BuildConfig.DEBUG) Log.d(TAG, "startInitialLoad: snapshot restored=$restored, notes=${_notes.value.size}, followedPubkeys=${_followedPubkeys.value.size}")
            if (restored) {
                topUpFromRelays()
            } else {
                refresh()
            }
        }
    }

    internal fun FeedService.refreshImpl() {
        scope.launch {
            _isLoadingFeed.value = true
            _connectionStatus.value = "Loading feed..."
            _connectionColor.value = "yellow"

            loadContactList()

            // Global is filtered against the trust graph; pick up one the relay
            // has written since the last read.
            if (isGlobalLikeMode()) loadWotPubkeys()
            // Global's thread replies were fetched under the old list and trust
            // setting (the shield's switch lands here); Threaded View fetches
            // them again for the reloaded posts.
            if (_feedMode.value == FeedMode.GLOBAL) resetFeedThreadReplies()

            when (_feedMode.value) {
                FeedMode.POPULAR -> loadPopularFeed() // Computed, not streamed: pull to refresh computes it again.
                FeedMode.DISCOVERY -> {
                    loadExtendedNetwork()
                    subscribeToAllRelays()
                }
                else -> subscribeToAllRelays()
            }
        }
    }

    internal fun FeedService.forceReloadImpl() {
        clearInMemoryFeedState()
        refresh()
    }

    internal fun FeedService.switchModeImpl(mode: FeedMode) {
        if (mode == _feedMode.value) return
        val previousSubId = primaryFeedSubId()
        captureModeCache(_feedMode.value)
        _feedMode.value = mode

        // Pending notes are raw, unfiltered for the previous mode — drop them so
        // the "New Posts" count doesn't carry over stale entries. Live subs for
        // the new mode will repopulate.
        _pendingNotes.value = emptyList()
        resetFeedThreadReplies()
        val cachedAgeMs = restoreModeCache(mode)
        when (mode) {
            FeedMode.POPULAR -> showCachedPopularOrLoad(cachedAgeMs)
            FeedMode.GLOBAL -> {
                loadWotPubkeys()
                subscribeToAllRelays()
            }
            FeedMode.DISCOVERY -> {
                // Discovery keeps only authors in the trust graph, same as Global.
                loadWotPubkeys()
                if (needsExtendedNetworkRefresh()) {
                    scope.launch {
                        loadExtendedNetwork()
                        subscribeToAllRelays()
                    }
                } else {
                    subscribeToAllRelays()
                }
            }
            FeedMode.MEDIA -> {
                // Global media is scoped to the web-of-trust set; make sure it's
                // populated before subscribing so the author filter isn't empty.
                if (_mediaFeedMode.value == MediaFeedMode.GLOBAL) loadWotPubkeys()
                subscribeToAllRelays()
            }
            FeedMode.ARTICLES, FeedMode.RECIPES, FeedMode.POLLS -> {
                if (longFormScope() == MediaFeedMode.GLOBAL) loadWotPubkeys()
                subscribeToAllRelays()
            }
            // These feeds run their own queries (Reels, Live, Marketplace,
            // Hashtags) or read Wavlake (Music). The timeline REQ idles; left
            // to subscribeToAllRelays, Live/Marketplace/Music sent a REQ with
            // no author or tag filter, the whole network.
            FeedMode.REELS, FeedMode.LIVE, FeedMode.MARKETPLACE,
            FeedMode.MUSIC, FeedMode.HASHTAGS -> closePrimaryFeedSubscription(previousSubId)
            else -> subscribeToAllRelays()
        }
        recomputeFilteredNotes()
    }

    /**
     * Switch the media sub-feed between Following and Global (iOS parity).
     * Re-subscribes with the new author scope and recomputes the media grid.
     */
    /** Following / Global for Articles, Recipes or Polls; re-subscribes like Media. */
    internal fun FeedService.setLongFormFeedModeImpl(feed: FeedMode, mode: MediaFeedMode) {
        val flow = when (feed) {
            FeedMode.ARTICLES -> _articlesFeedMode
            FeedMode.RECIPES -> _recipesFeedMode
            FeedMode.POLLS -> _pollsFeedMode
            else -> return
        }
        if (flow.value == mode) return
        flow.value = mode
        _pendingNotes.value = emptyList()
        if (mode == MediaFeedMode.GLOBAL) loadWotPubkeys()
        subscribeToAllRelays()
        recomputeFilteredNotes()
    }

    internal fun FeedService.setMediaFeedModeImpl(mode: MediaFeedMode) {
        if (mode == _mediaFeedMode.value) return
        _mediaFeedMode.value = mode

        // Pending notes were scoped to the previous media filter; drop them so the
        // "New Posts" count doesn't carry stale entries into the new scope.
        _pendingNotes.value = emptyList()

        if (mode == MediaFeedMode.GLOBAL) loadWotPubkeys()
        subscribeToAllRelays()
        recomputeFilteredNotes()
    }

    /**
     * Called when the app is backgrounded.
     * Persists a snapshot for instant resume now; the feed WebSockets close
     * [FeedService.PAUSE_GRACE_MS] later ([FeedService.pauseGrace]), to free
     * network/memory while the relay keeps running via the foreground service.
     * A quicker return finds them open.
     */
    internal fun FeedService.pauseFeedImpl() {
        if (BuildConfig.DEBUG) Log.d(TAG, "pauseFeed: persisting snapshot; feed clients close after the grace")
        persistCurrentSnapshot()
        saveInteractionState()
        pauseGrace.pause()
    }

    /**
     * Called when the app returns to the foreground.
     * Restores the disk snapshot immediately (instant UI), then reconnects to
     * relay WebSockets in the background to top up with any events that arrived
     * while backgrounded.
     */
    internal fun FeedService.resumeFeedImpl() {
        if (BuildConfig.DEBUG) Log.d(TAG, "resumeFeed: notes=${_notes.value.size}, followedPubkeys=${_followedPubkeys.value.size}")

        // Back inside the grace: the sockets never closed and their REQs are
        // still live, so there is nothing to redial. A socket that dropped
        // meanwhile is redialling on its own; give it a fresh set of tries.
        if (pauseGrace.resume() && feedClients.isNotEmpty()) {
            if (BuildConfig.DEBUG) Log.d(TAG, "resumeFeed: back inside the grace, sockets kept")
            feedClients.values.forEach { it.resetReconnect() }
            prewarmAvatarCache(_notes.value)
            return
        }

        // A launch that restores the saved feed never reaches startInitialLoad,
        // which is otherwise where Global and Discovery get their trust graph.
        loadWotPubkeys()

        // If we still have notes in memory (brief background), just reconnect —
        // no need to hit disk or re-fetch contacts at all.
        if (_notes.value.isNotEmpty()) {
            if (BuildConfig.DEBUG) Log.d(TAG, "resumeFeed: notes still in memory, reconnecting only")
            // Memory cache may have been evicted while backgrounded — re-warm avatars
            prewarmAvatarCache(_notes.value)
            subscribeToAllRelays()
            return
        }

        scope.launch {
            // Notes were evicted (long background / memory trim) — restore from disk
            val hadSnapshot = restoreFromDiskIfAvailable()
            if (!hadSnapshot) {
                refresh()
                return@launch
            }
            // Snapshot restored contacts too — just reconnect, skip loadContactList()
            subscribeToAllRelays()
        }
    }

    /**
     * Web of Trust / Everyone for Global and Media's Global. Re-filters
     * straight away, then reloads, so the switch visibly lands both ways:
     * back to the Web of Trust the untrusted posts go at once instead of
     * lingering in the list and the new-posts count (iOS #133).
     */
    internal fun FeedService.setGlobalShowsEveryoneImpl(on: Boolean) {
        if (configStore.config.value.globalShowsEveryone == on) return
        configStore.update { it.copy(globalShowsEveryone = on) }
        recomputeFilteredNotes()
        refresh()
    }

    /** Narrow Global to these ISO 639-1 codes; empty shows every language. */
    internal fun FeedService.setGlobalFeedLanguagesImpl(codes: List<String>) {
        configStore.update { it.copy(globalFeedLanguages = codes.distinct()) }
        recomputeFilteredNotes()
    }

    internal fun FeedService.setShowRepostsImpl(show: Boolean) {
        configStore.update { it.copy(showReposts = show) }
        recomputeFilteredNotes()
    }

    internal fun FeedService.setShowRepliesImpl(show: Boolean) {
        configStore.update { it.copy(showReplies = show) }
        recomputeFilteredNotes()
    }

    /** Polls' Open / Closed / All only re-filters: every poll is already loaded. */
    internal fun FeedService.setPollStatusFilterImpl(filter: com.nostrvault.data.model.PollStatusFilter) {
        if (_pollStatusFilter.value == filter) return
        _pollStatusFilter.value = filter
        recomputeFilteredNotes()
    }

    /** The service's long-lived collectors, started from its init block (where they always were). */
    internal fun FeedService.startObservers() {
        scope.launch {
            _notes.drop(1).collect { snapshotDirty = true }
        }
        // Which emoji went with each like, and which reactions were removed,
        // live only in the account's interaction-state file.
        scope.launch {
            val key = currentSnapshotKey()
            val saved = withContext(Dispatchers.IO) {
                engagementTracker.loadInteractionState(key, fallbackToLegacy = false)
            }
            if (currentSnapshotKey() == key) {
                _myReactions.value = saved.myReactions + _myReactions.value
                retractedReactionIds = retractedReactionIds + saved.retractedReactionIds
            }
        }
        // Every note that reaches the feed contributes its blob hashes to the
        // persistent index. `record` skips note ids it has already folded in, so
        // re-emissions of the same list cost a set lookup per note — up to
        // MAX_FEED_NOTES of them, so on Default rather than Main.
        scope.launch(processingDispatcher) {
            _notes.collect { blobNoteIndexStore.record(it) }
        }
        scope.launch {
            while (isActive) {
                delay(60_000)
                if (snapshotDirty && _notes.value.isNotEmpty() && _feedMode.value != FeedMode.POPULAR) {
                    snapshotDirty = false
                    persistCurrentSnapshot()
                }
            }
        }
        // forceReload() (clears notes/follows/extended-network + reconnects) existed
        // but nothing ever called it on account switch — confirmed bug: the Feed tab
        // kept showing the previous account's stale notes/follows until they were
        // naturally evicted or the user manually pulled to refresh. NostrService has
        // its own separate handleAccountSwitch() for its own state; this is FeedService's
        // equivalent, mirroring that same observeAccountSwitch() pattern.
        // The saved switches arrive when the config loads from disk.
        scope.launch {
            configStore.config
                .map { it.showReposts to it.showReplies }
                .distinctUntilChanged()
                .drop(1)
                .collect { recomputeFilteredNotes() }
        }

        scope.launch {
            configStore.accountSwitches
                .collect {
                    // The new account's list is unknown until its own load
                    // answers, and a tap queued under the previous account
                    // must not reach this one.
                    contactListConfirmed = false
                    forgetFollowListForAccountSwitch()
                    pendingFollowActions.clear()
                    notificationManager.clearPendingFollows()
                    forceReload()
                    // Likes and zaps are the account's own: the previous
                    // one's showed under Relay > Given (iOS loads them per
                    // account on switch). No legacy fallback, which would
                    // hand a new account someone else's.
                    _likedEventIds.value = emptySet()
                    _zappedEventIds.value = emptyMap()
                    _myReactions.value = emptyMap()
                    retractedReactionIds = emptySet()
                    // A reaction still being signed belongs to the previous account.
                    pendingReactionTokens.clear()
                    val key = currentSnapshotKey()
                    val saved = withContext(Dispatchers.IO) {
                        engagementTracker.loadInteractionState(key, fallbackToLegacy = false)
                    }
                    if (currentSnapshotKey() == key) {
                        _likedEventIds.value = _likedEventIds.value + saved.likedEventIds
                        _zappedEventIds.value = saved.zappedEventIds + _zappedEventIds.value
                        _myReactions.value = saved.myReactions + _myReactions.value
                        retractedReactionIds = retractedReactionIds + saved.retractedReactionIds
                    }
                }
        }
        // Follows' relay lists arrive in batches after the feed is up; once
        // they settle, ask the new outbox relays (see reconcileOutboxRelays).
        scope.launch {
            nostrService.outboxRelays
                .map { it.size }
                .distinctUntilChanged()
                .drop(1)
                .collectLatest {
                    delay(OUTBOX_RELAY_LIST_SETTLE_MS)
                    reconcileOutboxRelays()
                }
        }
        // Blocking someone (from a menu, Settings, or a mute list synced from
        // another client) must drop their posts now, not when some unrelated
        // note next arrives.
        scope.launch {
            configStore.config
                .map { it.blockedForActiveAccount() }
                .distinctUntilChanged()
                .drop(1)
                .collect { recomputeFilteredNotes() }
        }
    }

/** A launch prewarm runs once, before the first load, and not for Popular (computed, not cached). */
internal fun shouldPrewarm(mode: FeedMode, notesEmpty: Boolean, restored: Boolean, loadStarted: Boolean): Boolean =
    mode != FeedMode.POPULAR && notesEmpty && !restored && !loadStarted

/**
 * The relay is ready: load when the feed is empty, as before, and also when the
 * only notes are the prewarmed cache, which still needs its top-up.
 */
internal fun shouldStartInitialLoad(notesEmpty: Boolean, restored: Boolean, loadStarted: Boolean): Boolean =
    notesEmpty || (restored && !loadStarted)
