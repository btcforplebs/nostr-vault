package com.nostrvault.service

import android.content.Context
import android.util.Log
import coil.ImageLoader
import coil.request.CachePolicy
import coil.request.ImageRequest
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.EngagementTracker
import com.nostrvault.data.model.*
import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.relay.HavenBridge
import com.nostrvault.ui.notification.FollowKind
import com.nostrvault.ui.notification.NotificationManager
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.locks.ReentrantLock
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.concurrent.withLock

/**
 * Feed composition service.
 * Manages feed loading, pagination, contact lists, engagement tracking,
 * filtering, and account snapshot persistence.
 *
 * Port of FeedService.swift.
 */
@Singleton
class FeedService @Inject constructor(
    @ApplicationContext private val appContext: Context,
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
    private val feedFilterEngine: FeedFilterEngine,
    private val engagementTracker: EngagementTracker,
    private val contactManager: ContactManager,
    private val imageLoader: ImageLoader,
    private val notificationManager: NotificationManager,
    private val followingBackupService: FollowingBackupService,
) {
    companion object {
        private const val TAG = "FeedService"
        private const val MAX_FEED_NOTES = 800
        private const val MAX_PENDING_NOTES = 200
        private const val MAX_RAW_EVENT_CACHE = 1000
        private const val MAX_INJECTED_IDS = 10_000
        private const val CONTACT_LOAD_TIMEOUT_MS = 15_000L
        private const val FEED_LOAD_TIMEOUT_MS = 20_000L
        private const val EXTENDED_NETWORK_TIMEOUT_MS = 15_000L
        private const val NOTE_FETCH_TIMEOUT_MS = 8_000L
        private const val SEARCH_TIMEOUT_MS = 10_000L
        private const val SEARCH_DEBOUNCE_MS = 400L
        private const val INTERACTION_SAVE_THROTTLE_MS = 2_000L
        private const val FLUSH_INTERVAL_STANDARD_MS = 800L
        private const val FLUSH_INTERVAL_GLOBAL_MS = 50L
        private const val NOTE_BATCH_DELAY_MS = 150L
        private const val STAGGER_RELAY_MS = 200L
        private const val SNAPSHOT_MAX_AGE_MS = 24 * 60 * 60 * 1000L // 24 hours
        private const val SNAPSHOT_MAX_NOTES = 200
        private const val EXTENDED_NETWORK_CACHE_MS = 60 * 60 * 1000L // 1 hour
        private const val MAX_SEEN_IDS = 10_000
        private const val RECOMPUTE_DEBOUNCE_MS = 50L
        private const val AVATAR_PREWARM_COUNT = 80 // Warm cache for ~4 screens of visible notes
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val processingDispatcher = Dispatchers.Default
    private val json = Json { ignoreUnknownKeys = true }

    // ── Observable state ──────────────────────────────────────────────

    private val _feedMode = MutableStateFlow(
        configStore.config.value.defaultFeedMode
            .let { name -> FeedMode.entries.find { it.name == name } }
            ?: FeedMode.FOLLOWING
    )
    val feedMode: StateFlow<FeedMode> = _feedMode.asStateFlow()

    private val _mediaFeedMode = MutableStateFlow(MediaFeedMode.FOLLOWING)
    val mediaFeedMode: StateFlow<MediaFeedMode> = _mediaFeedMode.asStateFlow()

    private val _notes = MutableStateFlow<List<FeedNote>>(emptyList())
    val notes: StateFlow<List<FeedNote>> = _notes.asStateFlow()

    private val _filteredNotes = MutableStateFlow<List<FeedNote>>(emptyList())
    val filteredNotes: StateFlow<List<FeedNote>> = _filteredNotes.asStateFlow()

    private val _filteredMediaNotes = MutableStateFlow<List<FeedNote>>(emptyList())
    val filteredMediaNotes: StateFlow<List<FeedNote>> = _filteredMediaNotes.asStateFlow()

    private val _parentNotesCache = MutableStateFlow<Map<String, FeedNote>>(emptyMap())
    val parentNotesCache: StateFlow<Map<String, FeedNote>> = _parentNotesCache.asStateFlow()

    private val _followedPubkeys = MutableStateFlow<List<String>>(emptyList())
    val followedPubkeys: StateFlow<List<String>> = _followedPubkeys.asStateFlow()

    private val _extendedNetworkPubkeys = MutableStateFlow<List<String>>(emptyList())
    val extendedNetworkPubkeys: StateFlow<List<String>> = _extendedNetworkPubkeys.asStateFlow()

    private val _isLoadingContacts = MutableStateFlow(false)
    val isLoadingContacts: StateFlow<Boolean> = _isLoadingContacts.asStateFlow()

    private val _isLoadingExtendedNetwork = MutableStateFlow(false)
    val isLoadingExtendedNetwork: StateFlow<Boolean> = _isLoadingExtendedNetwork.asStateFlow()

    private val _hasAttemptedContactLoad = MutableStateFlow(false)
    val hasAttemptedContactLoad: StateFlow<Boolean> = _hasAttemptedContactLoad.asStateFlow()

    private val _isLoadingFeed = MutableStateFlow(false)
    val isLoadingFeed: StateFlow<Boolean> = _isLoadingFeed.asStateFlow()

    private val _isLoadingPopular = MutableStateFlow(false)
    val isLoadingPopular: StateFlow<Boolean> = _isLoadingPopular.asStateFlow()

    private val _isSyncing = MutableStateFlow(false)
    val isSyncing: StateFlow<Boolean> = _isSyncing.asStateFlow()

    private val _feedScrollingDown = MutableStateFlow(false)
    val feedScrollingDown: StateFlow<Boolean> = _feedScrollingDown.asStateFlow()

    private val _connectionStatus = MutableStateFlow("Disconnected")
    val connectionStatus: StateFlow<String> = _connectionStatus.asStateFlow()

    private val _connectionColor = MutableStateFlow("gray")
    val connectionColor: StateFlow<String> = _connectionColor.asStateFlow()

    private val _newNoteCount = MutableStateFlow(0)
    val newNoteCount: StateFlow<Int> = _newNoteCount.asStateFlow()

    private val _pendingNotes = MutableStateFlow<List<FeedNote>>(emptyList())
    val pendingNotes: StateFlow<List<FeedNote>> = _pendingNotes.asStateFlow()

    private val _likedEventIds = MutableStateFlow<Set<String>>(emptySet())
    val likedEventIds: StateFlow<Set<String>> = _likedEventIds.asStateFlow()

    private val _repostedEventIds = MutableStateFlow<Set<String>>(emptySet())
    val repostedEventIds: StateFlow<Set<String>> = _repostedEventIds.asStateFlow()

    private val _zappedEventIds = MutableStateFlow<Map<String, Int>>(emptyMap())
    val zappedEventIds: StateFlow<Map<String, Int>> = _zappedEventIds.asStateFlow()

    private val _noteStats = MutableStateFlow<Map<String, NoteStats>>(emptyMap())
    val noteStats: StateFlow<Map<String, NoteStats>> = _noteStats.asStateFlow()

    private val _isSearchActive = MutableStateFlow(false)
    val isSearchActive: StateFlow<Boolean> = _isSearchActive.asStateFlow()

    private val _searchQuery = MutableStateFlow("")
    val searchQuery: StateFlow<String> = _searchQuery.asStateFlow()

    private val _searchResults = MutableStateFlow<List<FeedNote>>(emptyList())
    val searchResults: StateFlow<List<FeedNote>> = _searchResults.asStateFlow()

    private val _isSearching = MutableStateFlow(false)
    val isSearching: StateFlow<Boolean> = _isSearching.asStateFlow()

    private val _showReposts = MutableStateFlow(true)
    val showReposts: StateFlow<Boolean> = _showReposts.asStateFlow()

    private val _showReplies = MutableStateFlow(true)
    val showReplies: StateFlow<Boolean> = _showReplies.asStateFlow()

    private val _popularFilter = MutableStateFlow(PopularFilter.ALL)
    val popularFilter: StateFlow<PopularFilter> = _popularFilter.asStateFlow()

    private val _showPopularEngagement = MutableStateFlow(true)
    val showPopularEngagement: StateFlow<Boolean> = _showPopularEngagement.asStateFlow()

    private val _popularNoteScores = MutableStateFlow<Map<String, Double>>(emptyMap())
    val popularNoteScores: StateFlow<Map<String, Double>> = _popularNoteScores.asStateFlow()

    private val _wotPubkeys = MutableStateFlow<Set<String>>(emptySet())
    val wotPubkeys: StateFlow<Set<String>> = _wotPubkeys.asStateFlow()

    private val _parentIsNextNote = MutableStateFlow<Set<String>>(emptySet())
    val parentIsNextNote: StateFlow<Set<String>> = _parentIsNextNote.asStateFlow()

    val isInjecting = MutableStateFlow(false)

    // ── Internal state ────────────────────────────────────────────────

    private val seenIds = LinkedHashSet<String>()
    private val seenIdsLock = ReentrantLock()
    private val rawEventCache = ConcurrentHashMap<String, String>()
    private val injectedEventIds = ConcurrentHashMap.newKeySet<String>()
    private val feedClients = ConcurrentHashMap<String, WebSocketClient>()
    // Collector Jobs per feed client (messages + connectionState). Tracked so they
    // can be cancelled on removal — client.messages is a SharedFlow that never
    // completes, so disconnect() alone leaves these coroutines (and the client)
    // pinned in memory forever.
    private val feedClientJobs = ConcurrentHashMap<String, MutableList<Job>>()
    // Relays whose auxiliary subscriptions (reactions/zaps) have been sent for the
    // current connection. Cleared on disconnect/teardown so reconnects re-send.
    private val auxSubsSent = ConcurrentHashMap.newKeySet<String>()

    // Background accumulator
    private val accumulator = BackgroundAccumulator()
    private var flushScheduled = false
    private val flushLock = ReentrantLock()
    private var isInitialLoad = false

    // Contact list content (for safety checks)
    private var contactListContent: String = ""

    // Account snapshots (in-memory)
    private val accountSnapshots = ConcurrentHashMap<String, AccountFeedSnapshot>()

    // Interaction state persistence
    private var lastInteractionSaveTime = 0L
    private var interactionSaveJob: Job? = null

    // Scroll position tracking for snapshot persistence
    private var _savedScrollIndex = 0
    private var _savedScrollOffset = 0

    private val _restoredScrollPosition = MutableStateFlow<ScrollPosition?>(null)
    val restoredScrollPosition: StateFlow<ScrollPosition?> = _restoredScrollPosition.asStateFlow()

    // Tab re-selection scroll-to-top event
    private val _scrollToTopRequest = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val scrollToTopRequest: SharedFlow<Unit> = _scrollToTopRequest.asSharedFlow()

    // Extended network caching
    private var lastExtendedNetworkLoadTime = 0L

    // Guards loadMore() against re-entry from scroll-triggered re-fires
    private val isLoadingMore = AtomicBoolean(false)

    // Search debounce
    private var searchDebounceJob: Job? = null

    // Filter recomputation coalescing
    private var recomputeJob: Job? = null

    // ══════════════════════════════════════════════════════════════════
    // Lifecycle
    // ══════════════════════════════════════════════════════════════════

    /**
     * Cold-launch entry point.
     * Restores disk snapshot if available, then tops up from relays.
     */
    fun startInitialLoad() {
        Log.d(TAG, "startInitialLoad: mode=${_feedMode.value}")

        // Pre-load WOT pubkeys so DISCOVERY and GLOBAL media modes work immediately
        loadWotPubkeys()

        if (_feedMode.value == FeedMode.POPULAR) {
            loadPopularFeed()
            return
        }

        scope.launch {
            val restored = restoreFromDiskIfAvailable()
            Log.d(TAG, "startInitialLoad: snapshot restored=$restored, notes=${_notes.value.size}, followedPubkeys=${_followedPubkeys.value.size}")
            if (restored) {
                topUpFromRelays()
            } else {
                refresh()
            }
        }
    }

    fun refresh() {
        scope.launch {
            _isLoadingFeed.value = true
            _connectionStatus.value = "Loading feed..."
            _connectionColor.value = "yellow"

            loadContactList()

            when (_feedMode.value) {
                FeedMode.DISCOVERY -> {
                    loadExtendedNetwork()
                    subscribeToAllRelays()
                }
                else -> subscribeToAllRelays()
            }
        }
    }

    fun forceReload() {
        clearInMemoryFeedState()
        refresh()
    }

    fun switchMode(mode: FeedMode) {
        if (mode == _feedMode.value) return
        _feedMode.value = mode

        when (mode) {
            FeedMode.POPULAR -> loadPopularFeed()
            FeedMode.GLOBAL -> {
                loadWotPubkeys()
                subscribeToAllRelays()
            }
            FeedMode.DISCOVERY -> {
                if (needsExtendedNetworkRefresh()) {
                    scope.launch {
                        loadExtendedNetwork()
                        subscribeToAllRelays()
                    }
                } else {
                    subscribeToAllRelays()
                }
            }
            else -> subscribeToAllRelays()
        }
        recomputeFilteredNotes()
    }

    /**
     * Called when the app is backgrounded.
     * Persists a snapshot for instant resume and disconnects feed WebSockets
     * to free network/memory while the relay keeps running via the foreground service.
     */
    fun pauseFeed() {
        Log.d(TAG, "pauseFeed: persisting snapshot and disconnecting feed clients")
        persistCurrentSnapshot()
        saveInteractionState()
        teardownAllFeedClients()
        _connectionStatus.value = "Paused"
        _connectionColor.value = "gray"
    }

    /**
     * Called when the app returns to the foreground.
     * Restores the disk snapshot immediately (instant UI), then reconnects to
     * relay WebSockets in the background to top up with any events that arrived
     * while backgrounded.
     */
    fun resumeFeed() {
        Log.d(TAG, "resumeFeed: notes=${_notes.value.size}, followedPubkeys=${_followedPubkeys.value.size}")

        // If we still have notes in memory (brief background), just reconnect —
        // no need to hit disk or re-fetch contacts at all.
        if (_notes.value.isNotEmpty()) {
            Log.d(TAG, "resumeFeed: notes still in memory, reconnecting only")
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

    fun disconnect() {
        teardownAllFeedClients()
        _connectionStatus.value = "Disconnected"
        _connectionColor.value = "gray"
    }

    // ══════════════════════════════════════════════════════════════════
    // Contact list management
    // ══════════════════════════════════════════════════════════════════

    private suspend fun loadContactList() {
        _isLoadingContacts.value = true
        Log.d(TAG, "loadContactList: starting, current followedPubkeys=${_followedPubkeys.value.size}")

        withContext(Dispatchers.IO) {
            try {
                val result = withTimeoutOrNull(CONTACT_LOAD_TIMEOUT_MS) {
                    fetchContactListFromRelays()
                }
                if (result != null) {
                    val (pubkeys, content) = result
                    Log.d(TAG, "loadContactList: found ${pubkeys.size} followed pubkeys")
                    withContext(Dispatchers.Main.immediate) {
                        _followedPubkeys.value = pubkeys
                        contactListContent = content
                        _hasAttemptedContactLoad.value = true
                        _isLoadingContacts.value = false
                        recomputeFilteredNotes()

                        // Auto-snapshot for following backup
                        val accountKey = configStore.config.value.activeAccountNpub
                            ?: configStore.config.value.ownerNpub
                        followingBackupService.maybeCreateSnapshot(
                            pubkeys = pubkeys,
                            pTags = emptyList(),
                            contactListContent = content,
                            forAccountKey = accountKey,
                        )
                    }
                } else {
                    Log.w(TAG, "loadContactList: no contact list found (timeout or empty relays)")
                    withContext(Dispatchers.Main.immediate) {
                        _hasAttemptedContactLoad.value = true
                        _isLoadingContacts.value = false
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "Contact list load failed: ${e.message}")
                withContext(Dispatchers.Main.immediate) {
                    _hasAttemptedContactLoad.value = true
                    _isLoadingContacts.value = false
                }
            }
        }
    }

    private suspend fun fetchContactListFromRelays(): Pair<List<String>, String>? {
        val config = configStore.config.value
        val relayUrls = buildList {
            config.nostrURL?.let { add(it) }
            config.inboxRelays?.let { addAll(it) }
            config.activeBlastrRelays.let { addAll(it) }
        }.distinct().take(5)

        Log.d(TAG, "fetchContactList: trying ${relayUrls.size} relays: $relayUrls")
        Log.d(TAG, "fetchContactList: activeHexPubkey=${nostrService.activeHexPubkey.take(16)}...")

        if (relayUrls.isEmpty()) {
            Log.w(TAG, "fetchContactList: no relay URLs configured!")
            return null
        }

        return suspendCancellableCoroutine { cont ->
            var completed = false
            val completeLock = ReentrantLock()

            for (relayUrl in relayUrls) {
                scope.launch(Dispatchers.IO) {
                    val client = WebSocketClient(url = relayUrl, scope = scope, trustLocalhost = relayUrl.contains("localhost") || relayUrl.contains("127.0.0.1"))
                    val subId = "contacts-${UUID.randomUUID().toString().take(8)}"

                    // Tracked so it can be cancelled after disconnect — messages is a
                    // SharedFlow that never completes, so this would otherwise leak.
                    val collector = scope.launch {
                        client.messages.collect { msg ->
                            try {
                                val parsed = json.parseToJsonElement(msg).jsonArray
                                if (parsed.size >= 3 && parsed[0].jsonPrimitive.contentOrNull == "EVENT") {
                                    val eventObj = parsed[2].jsonObject
                                    val kind = eventObj["kind"]?.jsonPrimitive?.intOrNull
                                    if (kind == 3) {
                                        val tags = eventObj["tags"]?.jsonArray?.map { tagArr ->
                                            tagArr.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" }
                                        } ?: emptyList()
                                        val content = eventObj["content"]?.jsonPrimitive?.contentOrNull ?: ""

                                        Log.d(TAG, "fetchContactList: got kind:3 from $relayUrl with ${tags.size} tags")

                                        val ownerHex = nostrService.activeHexPubkey
                                        val whitelistedNpubs = configStore.config.value.whitelistedNpubs ?: emptyList()
                                        val contactResult = contactManager.parseContactList(tags, ownerHex, whitelistedNpubs)
                                        val pubkeys = contactResult.pubkeys
                                        Log.d(TAG, "fetchContactList: parsed ${pubkeys.size} pubkeys from ${tags.size} tags")
                                        if (pubkeys.isNotEmpty()) {
                                            completeLock.withLock {
                                                if (!completed) {
                                                    completed = true
                                                    cont.resume(pubkeys to content) {}
                                                }
                                            }
                                        }
                                    }
                                }
                            } catch (_: Exception) {}
                        }
                    }

                    client.connect()
                    val ownerHex = nostrService.activeHexPubkey
                    val filter = """{"kinds":[3],"authors":["$ownerHex"],"limit":1}"""
                    Log.d(TAG, "fetchContactList: sending REQ to $relayUrl")
                    client.send("[\"REQ\",\"$subId\",$filter]")

                    delay(CONTACT_LOAD_TIMEOUT_MS)
                    collector.cancel()
                    client.disconnect()
                    completeLock.withLock {
                        if (!completed) {
                            completed = true
                            Log.w(TAG, "fetchContactList: timed out on $relayUrl, no contacts found")
                            cont.resume(null) {}
                        }
                    }
                }
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Extended network (discovery mode)
    // ══════════════════════════════════════════════════════════════════

    private suspend fun loadExtendedNetwork() {
        _isLoadingExtendedNetwork.value = true
        withContext(Dispatchers.IO) {
            try {
                val follows = _followedPubkeys.value
                if (follows.isEmpty()) return@withContext

                // Build mutual counts from relay list data - pubkeys that appear
                // across multiple followed users' relay lists are likely extended network
                val mutualCounts = mutableMapOf<String, Int>()
                val followSet = follows.toSet()
                for ((pubkey, _) in nostrService.relayLists.value) {
                    if (pubkey !in followSet) {
                        mutualCounts[pubkey] = (mutualCounts[pubkey] ?: 0) + 1
                    }
                }
                val extended = contactManager.rankExtendedNetwork(mutualCounts)

                withContext(Dispatchers.Main.immediate) {
                    _extendedNetworkPubkeys.value = extended
                    _isLoadingExtendedNetwork.value = false
                    lastExtendedNetworkLoadTime = System.currentTimeMillis()
                }
            } catch (e: Exception) {
                Log.w(TAG, "Extended network load failed: ${e.message}")
                withContext(Dispatchers.Main.immediate) {
                    _isLoadingExtendedNetwork.value = false
                }
            }
        }
    }

    private fun needsExtendedNetworkRefresh(): Boolean {
        return System.currentTimeMillis() - lastExtendedNetworkLoadTime > EXTENDED_NETWORK_CACHE_MS
    }

    // ══════════════════════════════════════════════════════════════════
    // Relay subscription
    // ══════════════════════════════════════════════════════════════════

    private fun subscribeToAllRelays() {
        val config = configStore.config.value
        val relayUrls = buildList {
            config.nostrURL?.let { add(it) }
            config.localInboxURL?.let { add(it) }
            config.inboxRelays?.let { addAll(it) }
            // Follows publish to feed/blastr relays, not just the local + inbox
            // set. Mirror iOS (externalRelayURLs) and the fetchReplies fix so
            // follows who post elsewhere actually appear in the feed.
            addAll(config.activeFeedRelays)
            addAll(config.activeBlastrRelays)
            if (config.activeFeedRelays.isEmpty() &&
                config.activeBlastrRelays.isEmpty() &&
                config.inboxRelays.isNullOrEmpty()) {
                add("wss://relay.damus.io")
                add("wss://relay.primal.net")
                add("wss://nos.lol")
            }
        }.distinct()

        // Disconnect stale clients that are no longer in the relay set,
        // and skip URLs that already have a live connection.
        val staleKeys = feedClients.keys - relayUrls.toSet()
        for (key in staleKeys) {
            teardownFeedClient(key)
        }

        _isLoadingFeed.value = true
        isInitialLoad = true
        _connectionStatus.value = "Connecting..."
        _connectionColor.value = "yellow"

        for ((index, relayUrl) in relayUrls.withIndex()) {
            // Reuse an existing connected client instead of creating a duplicate
            val existing = feedClients[relayUrl]
            if (existing != null && existing.connectionState.value == WebSocketClient.ConnectionState.CONNECTED) {
                // Already connected — just re-send the subscription filter
                val label = when (_feedMode.value) {
                    FeedMode.FOLLOWING -> "following"
                    FeedMode.DISCOVERY -> "discovery"
                    FeedMode.GLOBAL -> "global"
                    FeedMode.MEDIA -> "media"
                    FeedMode.POPULAR -> "popular"
                }
                sendPrimaryFeedSubscription(relayUrl, "feed-$label")
                continue
            }
            // Tear down any half-dead client (and its collectors) before replacing it
            if (existing != null) teardownFeedClient(relayUrl)

            scope.launch(Dispatchers.IO) {
                // Stagger external relays
                if (index > 1) delay(index * STAGGER_RELAY_MS)
                connectFeedRelay(relayUrl)
            }
        }

        // Arm feed timeout
        scope.launch {
            delay(FEED_LOAD_TIMEOUT_MS)
            if (_isLoadingFeed.value) {
                _isLoadingFeed.value = false
                _isSyncing.value = false
                flushAccumulator()
            }
        }
    }

    /** Cancel a feed client's collectors and disconnect it. */
    private fun teardownFeedClient(relayUrl: String) {
        feedClientJobs.remove(relayUrl)?.forEach { it.cancel() }
        feedClients.remove(relayUrl)?.disconnect()
        auxSubsSent.remove(relayUrl)
    }

    /** Cancel and disconnect every feed client. */
    private fun teardownAllFeedClients() {
        feedClientJobs.values.forEach { jobs -> jobs.forEach { it.cancel() } }
        feedClientJobs.clear()
        feedClients.values.forEach { it.disconnect() }
        feedClients.clear()
        auxSubsSent.clear()
    }

    /** Subscription id of the primary feed REQ for the current mode. */
    private fun primaryFeedSubId(): String {
        val label = when (_feedMode.value) {
            FeedMode.FOLLOWING -> "following"
            FeedMode.DISCOVERY -> "discovery"
            FeedMode.GLOBAL -> "global"
            FeedMode.MEDIA -> "media"
            FeedMode.POPULAR -> "popular"
        }
        return "feed-$label"
    }

    private fun connectFeedRelay(relayUrl: String) {
        val subId = primaryFeedSubId()

        val client = WebSocketClient(
            url = relayUrl,
            scope = scope,
            trustLocalhost = relayUrl.contains("localhost") || relayUrl.contains("127.0.0.1"),
        )
        // Replacing an existing client for this URL: tear down its collectors first.
        teardownFeedClient(relayUrl)
        feedClients[relayUrl] = client

        val messagesJob = scope.launch {
            client.messages.collect { msg ->
                launch(processingDispatcher) {
                    processAccumulatorMessage(msg, relayUrl)
                }
            }
        }

        val stateJob = scope.launch {
            client.connectionState.collect { state ->
                when (state) {
                    WebSocketClient.ConnectionState.CONNECTED -> {
                        sendPrimaryFeedSubscription(relayUrl, subId)
                        // Mentions go out with the primary feed — they double as
                        // notifications, so they must not wait for feed EOSE.
                        sendMentionSubscription(relayUrl)
                        updateFeedConnectionStatus()
                    }
                    WebSocketClient.ConnectionState.DISCONNECTED -> {
                        // New connection gets a fresh auxiliary-subscription pass
                        auxSubsSent.remove(relayUrl)
                        updateFeedConnectionStatus()
                    }
                    else -> {}
                }
            }
        }
        feedClientJobs[relayUrl] = mutableListOf(messagesJob, stateJob)

        client.connect()
    }

    private fun sendPrimaryFeedSubscription(relayUrl: String, subId: String) {
        val client = feedClients[relayUrl] ?: return
        val ownerHex = nostrService.activeHexPubkey

        val filter = buildString {
            append("{\"kinds\":[1,6,30023]")
            when (_feedMode.value) {
                FeedMode.FOLLOWING -> {
                    // Send the full follow list (iOS does not cap); capping at
                    // 500 silently hid notes from any follows beyond that.
                    val authors = _followedPubkeys.value
                    if (authors.isNotEmpty()) {
                        append(",\"authors\":[${authors.joinToString(",") { "\"$it\"" }}]")
                    }
                }
                FeedMode.DISCOVERY -> {
                    val authors = _extendedNetworkPubkeys.value.take(500)
                    if (authors.isNotEmpty()) {
                        append(",\"authors\":[${authors.joinToString(",") { "\"$it\"" }}]")
                    }
                }
                FeedMode.GLOBAL -> {
                    // No author restriction
                }
                FeedMode.MEDIA -> {
                    val authors = when (_mediaFeedMode.value) {
                        MediaFeedMode.FOLLOWING -> _followedPubkeys.value.take(500)
                        MediaFeedMode.GLOBAL -> _wotPubkeys.value.take(500).toList()
                    }
                    if (authors.isNotEmpty()) {
                        append(",\"authors\":[${authors.joinToString(",") { "\"$it\"" }}]")
                    }
                }
                FeedMode.POPULAR -> return // Handled separately
            }

            // Since timestamp
            val oldest = _notes.value.lastOrNull()?.createdAt
            if (oldest != null) {
                append(",\"since\":${oldest.time / 1000}")
            } else {
                val sevenDaysAgo = System.currentTimeMillis() / 1000 - (7 * 24 * 60 * 60)
                append(",\"since\":$sevenDaysAgo")
            }
            append(",\"limit\":500}")
        }

        Log.d(TAG, "sendPrimaryFeedSubscription: $relayUrl subId=$subId followedPubkeys=${_followedPubkeys.value.size}")
        client.send("[\"REQ\",\"$subId\",$filter]")
    }

    private fun updateFeedConnectionStatus() {
        val connected = feedClients.values.count {
            it.connectionState.value == WebSocketClient.ConnectionState.CONNECTED
        }
        val total = feedClients.size
        when {
            connected == 0 && total == 0 -> {
                _connectionStatus.value = "Disconnected"
                _connectionColor.value = "gray"
            }
            connected == 0 -> {
                _connectionStatus.value = "Connecting..."
                _connectionColor.value = "yellow"
            }
            connected < total -> {
                _connectionStatus.value = "Live ($connected/$total)"
                _connectionColor.value = "yellow"
            }
            else -> {
                _connectionStatus.value = "Live"
                _connectionColor.value = "green"
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Background accumulator
    // ══════════════════════════════════════════════════════════════════

    private fun processAccumulatorMessage(message: String, relayUrl: String) {
        try {
            val parsed = json.parseToJsonElement(message).jsonArray
            if (parsed.isEmpty()) return
            val type = parsed[0].jsonPrimitive.contentOrNull ?: return

            when (type) {
                "EVENT" -> {
                    if (parsed.size < 3) return
                    val subId = parsed[1].jsonPrimitive.contentOrNull ?: return
                    val eventObj = parsed[2].jsonObject

                    // Metadata events go to NostrService directly
                    val kind = eventObj["kind"]?.jsonPrimitive?.intOrNull ?: return
                    if (kind in listOf(0, 10002, 10050, 10063, 10000)) {
                        nostrService.processRelayMessage(message, relayUrl)
                        return
                    }

                    // Feed notes → accumulator
                    accumulateEvent(eventObj, relayUrl)

                    // Inject mention events into local relay inbox so they persist
                    if (subId == "feed-mentions") {
                        val eventId = eventObj["id"]?.jsonPrimitive?.contentOrNull
                        if (eventId != null) {
                            injectExternalEvent(eventObj.toString(), eventId)
                        }
                    }
                }
                "EOSE" -> {
                    if (parsed.size >= 2) {
                        val subId = parsed[1].jsonPrimitive.contentOrNull ?: ""
                        handleFeedEOSE(subId, relayUrl)
                    }
                }
                else -> {}
            }
        } catch (e: Exception) {
            Log.w(TAG, "Accumulator parse error: ${e.message}")
        }
    }

    private fun accumulateEvent(eventObj: JsonObject, relayUrl: String) {
        val id = eventObj["id"]?.jsonPrimitive?.contentOrNull ?: return
        val pubkey = eventObj["pubkey"]?.jsonPrimitive?.contentOrNull ?: return
        val kind = eventObj["kind"]?.jsonPrimitive?.intOrNull ?: return
        val content = eventObj["content"]?.jsonPrimitive?.contentOrNull ?: ""
        val createdAt = eventObj["created_at"]?.jsonPrimitive?.longOrNull ?: return

        val tags = eventObj["tags"]?.jsonArray?.map { tagArr ->
            tagArr.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" }
        } ?: emptyList()

        // Dedup. On overflow, rebuild from currently retained notes (iOS parity)
        // instead of FIFO-evicting — keeps the set aligned with what's displayed.
        val isNew = seenIdsLock.withLock {
            val added = seenIds.add(id)
            if (added && seenIds.size > MAX_SEEN_IDS) {
                val retained = HashSet<String>(_notes.value.size + _pendingNotes.value.size + 100)
                _notes.value.forEach { retained.add(it.id) }
                _pendingNotes.value.forEach { retained.add(it.id) }
                seenIds.retainAll(retained)
                seenIds.add(id)
            }
            added
        }
        if (!isNew) return

        // Reject future-dated events
        val nowSecs = System.currentTimeMillis() / 1000
        if (createdAt > nowSecs + 60) return

        when (kind) {
            7 -> {
                // Reaction event — track engagement
                val targetId = tags.firstOrNull { it.size >= 2 && it[0] == "e" }?.get(1) ?: return
                accumulator.addReaction(targetId, pubkey)
            }
            9735 -> {
                // Zap receipt — track engagement
                val zapReceipt = ZapService.parseZapReceipt(id, pubkey, content, tags, createdAt)
                zapReceipt?.targetEventId?.let { targetId ->
                    accumulator.addZap(targetId, zapReceipt.amountSats)
                }
            }
            else -> {
                // Content note
                val note = FeedNote.fromEvent(id, pubkey, content, tags, createdAt, kind)
                if (note.isNoiseOrSpam()) return

                accumulator.addNote(note)

                // Cache raw event JSON
                val rawJson = eventObj.toString()
                rawEventCache[id] = rawJson
                if (rawEventCache.size > MAX_RAW_EVENT_CACHE) {
                    val keysToRemove = rawEventCache.keys.take(rawEventCache.size - MAX_RAW_EVENT_CACHE)
                    keysToRemove.forEach { rawEventCache.remove(it) }
                }

                // Queue profile fetch for unknown authors
                nostrService.fetchMissingProfiles(listOf(pubkey))
            }
        }

        scheduleBackgroundFlush()
    }

    private fun handleFeedEOSE(subId: String, relayUrl: String) {
        // Auxiliary subscriptions fire once per connection, on the PRIMARY feed's
        // EOSE only. A prefix match here would also fire on the auxiliary subs'
        // own EOSEs and loop forever (REQ → EOSE → REQ ...) against every relay.
        if (subId == primaryFeedSubId() && auxSubsSent.add(relayUrl)) {
            sendAuxiliarySubscriptions(relayUrl)
        }

        // Flush accumulated notes
        scope.launch {
            delay(100)
            flushAccumulator()
            _isLoadingFeed.value = false
            _isSyncing.value = false
            isInitialLoad = false
        }
    }

    private fun sendMentionSubscription(relayUrl: String) {
        val client = feedClients[relayUrl] ?: return
        val ownerHex = nostrService.activeHexPubkey
        if (ownerHex.isEmpty()) return
        val mentionFilter = """{"kinds":[1,6,30023],"#p":["$ownerHex"],"limit":50}"""
        client.send("[\"REQ\",\"feed-mentions\",$mentionFilter]")
    }

    private fun sendAuxiliarySubscriptions(relayUrl: String) {
        val client = feedClients[relayUrl] ?: return
        val ownerHex = nostrService.activeHexPubkey

        // Reactions from followed
        val follows = _followedPubkeys.value.take(200)
        if (follows.isNotEmpty()) {
            val authorsJson = follows.joinToString(",") { "\"$it\"" }
            val reactionFilter = """{"kinds":[7],"authors":[$authorsJson],"limit":150}"""
            client.send("[\"REQ\",\"feed-reactions\",$reactionFilter]")
        }

        // Incoming zaps
        val zapInFilter = """{"kinds":[9735],"#p":["$ownerHex"],"limit":50}"""
        client.send("[\"REQ\",\"feed-zaps-in\",$zapInFilter]")

        // Outgoing zaps
        val zapOutFilter = """{"kinds":[9734],"authors":["$ownerHex"],"limit":50}"""
        client.send("[\"REQ\",\"feed-zaps-out\",$zapOutFilter]")
    }

    private fun scheduleBackgroundFlush() {
        flushLock.withLock {
            if (flushScheduled) return
            flushScheduled = true
        }

        val interval = if (_feedMode.value == FeedMode.GLOBAL || _mediaFeedMode.value == MediaFeedMode.GLOBAL) {
            FLUSH_INTERVAL_GLOBAL_MS
        } else {
            FLUSH_INTERVAL_STANDARD_MS
        }

        scope.launch {
            delay(interval)
            flushLock.withLock { flushScheduled = false }
            flushAccumulator()
        }
    }

    private fun flushAccumulator() {
        val batch = accumulator.drain()
        if (batch.notes.isEmpty() && batch.reactions.isEmpty() && batch.zaps.isEmpty()) return

        scope.launch(Dispatchers.Main.immediate) {
            deliverBackgroundBatch(batch)
        }
    }

    private fun deliverBackgroundBatch(batch: BackgroundAccumulator.Snapshot) {
        // Apply notes
        if (batch.notes.isNotEmpty()) {
            val currentNotes = _notes.value.toMutableList()
            currentNotes.addAll(batch.notes)
            currentNotes.sortByDescending { it.createdAt }
            if (currentNotes.size > MAX_FEED_NOTES) {
                _notes.value = currentNotes.take(MAX_FEED_NOTES)
            } else {
                _notes.value = currentNotes
            }
        }

        // Apply engagement
        val currentStats = _noteStats.value.toMutableMap()
        for ((targetId, pubkey) in batch.reactions) {
            val existing = currentStats[targetId] ?: NoteStats()
            currentStats[targetId] = existing.copy(
                reactionCount = existing.reactionCount + 1
            )
        }
        for ((targetId, amount) in batch.zaps) {
            val existing = currentStats[targetId] ?: NoteStats()
            currentStats[targetId] = existing.copy(
                zapCount = existing.zapCount + 1,
                zapAmountSats = existing.zapAmountSats + amount
            )
        }
        // Trim stats to only cover notes still in memory
        if (currentStats.size > MAX_FEED_NOTES) {
            val activeIds = _notes.value.map { it.id }.toSet() +
                _parentNotesCache.value.keys
            currentStats.keys.retainAll(activeIds)
        }
        _noteStats.value = currentStats

        // Fetch missing profiles for new note authors
        val newPubkeys = batch.notes.map { it.pubkey }.distinct()
        nostrService.fetchMissingProfiles(newPubkeys)

        recomputeFilteredNotes()
    }

    // ══════════════════════════════════════════════════════════════════
    // Filtering
    // ══════════════════════════════════════════════════════════════════

    /**
     * Coalesced filter recomputation.
     * Multiple rapid-fire calls (e.g. batch flush + engagement update + profile
     * update all within 50 ms) are collapsed into a single computation.
     */
    fun recomputeFilteredNotes() {
        recomputeJob?.cancel()
        recomputeJob = scope.launch(Dispatchers.Main.immediate) {
            delay(RECOMPUTE_DEBOUNCE_MS)
            doRecomputeFilteredNotes()
        }
    }

    private fun doRecomputeFilteredNotes() {
        val config = configStore.config.value
        val blockedPubkeys = config.blockedNpubs?.mapNotNull { nostrService.npubToHex(it) }?.toSet() ?: emptySet()

        _filteredNotes.value = feedFilterEngine.filterFeedNotes(
            notes = _notes.value,
            mode = _feedMode.value,
            blocked = blockedPubkeys,
            showReposts = _showReposts.value,
            showReplies = _showReplies.value,
            followedPubkeys = _followedPubkeys.value.toSet(),
            wotPubkeys = _wotPubkeys.value,
            popularFilter = _popularFilter.value,
            popularNoteScores = _popularNoteScores.value,
        )

        _filteredMediaNotes.value = feedFilterEngine.filterMediaNotes(
            notes = _notes.value,
            blocked = blockedPubkeys,
            wotPubkeys = _wotPubkeys.value,
            isGlobalMedia = _mediaFeedMode.value == MediaFeedMode.GLOBAL,
        )

        _parentIsNextNote.value = feedFilterEngine.computeParentIsNext(_filteredNotes.value)
    }

    fun setShowReposts(show: Boolean) {
        _showReposts.value = show
        recomputeFilteredNotes()
    }

    fun setShowReplies(show: Boolean) {
        _showReplies.value = show
        recomputeFilteredNotes()
    }

    fun setPopularFilter(filter: PopularFilter) {
        _popularFilter.value = filter
        recomputeFilteredNotes()
    }

    fun loadWotPubkeys() {
        scope.launch(Dispatchers.IO) {
            try {
                val config = configStore.config.value
                val wotCachePath = config.relayDataDir?.let { "$it/wot_cache.json" }
                if (wotCachePath != null) {
                    val file = File(wotCachePath)
                    if (file.exists()) {
                        val content = file.readText()
                        val pubkeys = json.decodeFromString<List<String>>(content)
                        withContext(Dispatchers.Main.immediate) {
                            _wotPubkeys.value = pubkeys.toSet()
                        }
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "WoT load failed: ${e.message}")
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Following / unfollowing
    // ══════════════════════════════════════════════════════════════════

    fun followUser(pubkey: String): Result<Unit> {
        if (!_hasAttemptedContactLoad.value) {
            return Result.failure(FollowActionError.ContactsNotLoaded)
        }
        val displayName = profileDisplayName(pubkey)
        val currentPTags = _followedPubkeys.value.map { listOf("p", it) }
        val result = contactManager.prepareFollow(
            pubkey = pubkey,
            currentPTags = currentPTags,
            currentPubkeys = _followedPubkeys.value,
            hasAttemptedLoad = _hasAttemptedContactLoad.value,
            isLoading = _isLoadingContacts.value,
        )
        return result.fold(
            onSuccess = { followResult ->
                _followedPubkeys.value = followResult.pubkeys
                publishContactList(followResult.pubkeys)
                notificationManager.showFollow(displayName, FollowKind.FOLLOWED)
                Result.success(Unit)
            },
            onFailure = {
                notificationManager.showFollow(displayName, FollowKind.FAILED(it.message ?: "Failed"))
                Result.failure(it)
            },
        )
    }

    fun unfollowUser(pubkey: String): Result<Unit> {
        if (!_hasAttemptedContactLoad.value) {
            return Result.failure(FollowActionError.ContactsNotLoaded)
        }
        val displayName = profileDisplayName(pubkey)
        val currentPTags = _followedPubkeys.value.map { listOf("p", it) }
        val result = contactManager.prepareUnfollow(
            pubkey = pubkey,
            activeAccountHex = nostrService.activeHexPubkey,
            currentPTags = currentPTags,
            currentPubkeys = _followedPubkeys.value,
            hasAttemptedLoad = _hasAttemptedContactLoad.value,
            isLoading = _isLoadingContacts.value,
        )
        return result.fold(
            onSuccess = { followResult ->
                if (contactManager.shouldBlockPublish(followResult.pubkeys.size, _followedPubkeys.value.size)) {
                    return Result.failure(FollowActionError.SafetyCheckFailed)
                }
                _followedPubkeys.value = followResult.pubkeys
                publishContactList(followResult.pubkeys)
                notificationManager.showFollow(displayName, FollowKind.UNFOLLOWED)
                Result.success(Unit)
            },
            onFailure = {
                notificationManager.showFollow(displayName, FollowKind.FAILED(it.message ?: "Failed"))
                Result.failure(it)
            },
        )
    }

    private fun publishContactList(pubkeys: List<String>) {
        val tags = pubkeys.map { listOf("p", it) }
        scope.launch(Dispatchers.IO) {
            val event = nostrService.signEvent(
                kind = 3,
                content = contactListContent,
                tags = tags,
            )
            event?.let { nostrService.postEvent(it) }
        }
    }

    /** Check if a pubkey is in the followed list. */
    fun isFollowing(pubkey: String): Boolean =
        _followedPubkeys.value.contains(pubkey)

    /** Best display name for a pubkey (profile name or truncated hex). */
    private fun profileDisplayName(pubkey: String): String =
        nostrService.profiles.value[pubkey]?.bestName ?: "${pubkey.take(8)}..."

    /** Alias for followUser(), used by ProfileViewModel. */
    fun followPubkey(pubkey: String) { followUser(pubkey) }

    /** Alias for unfollowUser(), used by ProfileViewModel. */
    fun unfollowPubkey(pubkey: String) { unfollowUser(pubkey) }

    fun restoreContactList(pTags: List<List<String>>, content: String) {
        val ownerHex = nostrService.activeHexPubkey
        val whitelistedNpubs = configStore.config.value.whitelistedNpubs ?: emptyList()
        val contactResult = contactManager.parseContactList(pTags, ownerHex, whitelistedNpubs)
        _followedPubkeys.value = contactResult.pubkeys
        contactListContent = content
        publishContactList(contactResult.pubkeys)
    }

    // ══════════════════════════════════════════════════════════════════
    // User moderation
    // ══════════════════════════════════════════════════════════════════

    fun blockUser(hexPubkey: String) {
        val npub = nostrService.hexToNpub(hexPubkey) ?: return
        val current = configStore.config.value.blockedNpubs?.toMutableList() ?: mutableListOf()
        if (npub in current) return
        current.add(npub)
        configStore.update { it.copy(blockedNpubs = current) }
        scope.launch(Dispatchers.IO) {
            nostrService.publishMuteList(configStore.config.value.ownerNpub, current)
        }
        _notes.value = _notes.value.filter { it.pubkey != hexPubkey }
        recomputeFilteredNotes()
    }

    fun unblockUser(hexPubkey: String) {
        val npub = nostrService.hexToNpub(hexPubkey) ?: return
        val current = configStore.config.value.blockedNpubs?.toMutableList() ?: return
        if (npub !in current) return
        current.remove(npub)
        configStore.update { it.copy(blockedNpubs = current) }
        scope.launch(Dispatchers.IO) {
            nostrService.publishMuteList(configStore.config.value.ownerNpub, current)
        }
    }

    fun isBlocked(hexPubkey: String): Boolean {
        val npub = nostrService.hexToNpub(hexPubkey) ?: return false
        return configStore.config.value.blockedNpubs?.contains(npub) == true
    }

    // ══════════════════════════════════════════════════════════════════
    // Note operations
    // ══════════════════════════════════════════════════════════════════

    fun addNote(note: FeedNote) {
        _notes.value = listOf(note) + _notes.value
        recomputeFilteredNotes()
    }

    fun removeNote(id: String) {
        _notes.value = _notes.value.filter { it.id != id }
        recomputeFilteredNotes()
    }

    fun applyPendingNotes() {
        val pending = _pendingNotes.value
        if (pending.isEmpty()) return

        _notes.value = (pending + _notes.value)
            .sortedByDescending { it.createdAt }
            .take(MAX_FEED_NOTES)
        _pendingNotes.value = emptyList()
        _newNoteCount.value = 0
        recomputeFilteredNotes()
    }

    fun markViewed() {
        _newNoteCount.value = 0
    }

    // ── Scroll position tracking ─────────────────────────────────

    fun updateScrollPosition(index: Int, offset: Int) {
        _savedScrollIndex = index
        _savedScrollOffset = offset
    }

    fun clearRestoredScrollPosition() {
        _restoredScrollPosition.value = null
    }

    fun requestScrollToTop() {
        _scrollToTopRequest.tryEmit(Unit)
    }

    fun findNote(id: String): FeedNote? {
        return _notes.value.firstOrNull { it.id == id }
    }

    // ══════════════════════════════════════════════════════════════════
    // Pagination
    // ══════════════════════════════════════════════════════════════════

    fun loadMore() {
        // In-flight guard: scroll-triggered, so without this it re-fires on every
        // bottom-reach and leaks a client + collector per relay each time.
        if (!isLoadingMore.compareAndSet(false, true)) return
        val oldest = _notes.value.lastOrNull()?.createdAt ?: run {
            isLoadingMore.set(false)
            return
        }
        val config = configStore.config.value
        val relayUrls = buildList {
            config.nostrURL?.let { add(it) }
            config.inboxRelays?.let { addAll(it) }
            // Match the live feed relay set so paginating older notes also
            // reaches follows who publish to feed/blastr relays.
            addAll(config.activeFeedRelays)
            addAll(config.activeBlastrRelays)
        }.distinct()

        scope.launch(Dispatchers.IO) {
            val subId = "feed-hist-${UUID.randomUUID().toString().take(8)}"
            val clients = mutableListOf<WebSocketClient>()
            val collectors = mutableListOf<Job>()
            try {
                for (relayUrl in relayUrls) {
                    val client = WebSocketClient(url = relayUrl, scope = scope, trustLocalhost = relayUrl.contains("localhost") || relayUrl.contains("127.0.0.1"))
                    clients.add(client)

                    // Track the collector so it can be cancelled on cleanup —
                    // WebSocketClient.messages is a SharedFlow that never completes,
                    // so disconnect() alone leaves this coroutine (and the client)
                    // pinned in memory forever.
                    collectors.add(scope.launch {
                        client.messages.collect { msg ->
                            launch(processingDispatcher) {
                                processAccumulatorMessage(msg, relayUrl)
                            }
                        }
                    })

                    client.connect()

                    val filter = buildString {
                        append("{\"kinds\":[1,6,30023]")
                        if (_feedMode.value == FeedMode.FOLLOWING) {
                            // Full follow list (matches the live feed; iOS uncapped).
                            val authors = _followedPubkeys.value
                            if (authors.isNotEmpty()) {
                                append(",\"authors\":[${authors.joinToString(",") { "\"$it\"" }}]")
                            }
                        }
                        append(",\"until\":${oldest.time / 1000 - 1}")
                        append(",\"limit\":100}")
                    }

                    client.send("[\"REQ\",\"$subId\",$filter]")
                }

                delay(NOTE_FETCH_TIMEOUT_MS)
            } finally {
                collectors.forEach { it.cancel() }
                clients.forEach { it.disconnect() }
                isLoadingMore.set(false)
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Note fetching (threading)
    // ══════════════════════════════════════════════════════════════════

    fun fetchMissingNote(id: String) {
        if (_parentNotesCache.value.containsKey(id)) return

        scope.launch(Dispatchers.IO) {
            val config = configStore.config.value
            val relayUrls = buildList {
                config.nostrURL?.let { add(it) }
                config.inboxRelays?.let { addAll(it.take(2)) }
            }

            val subId = "tfetch-${UUID.randomUUID().toString().take(8)}"
            val filter = """{"ids":["$id"]}"""

            val tempClients = mutableListOf<WebSocketClient>()
            val collectors = mutableListOf<Job>()
            for (relayUrl in relayUrls) {
                val existingClient = feedClients[relayUrl]
                val client: WebSocketClient
                if (existingClient != null) {
                    client = existingClient
                } else {
                    client = WebSocketClient(url = relayUrl, scope = scope, trustLocalhost = relayUrl.contains("localhost") || relayUrl.contains("127.0.0.1"))
                    tempClients.add(client)
                    client.connect()
                }

                // Tracked so it is cancelled below. Critical for reused persistent
                // feed clients: an un-cancelled collector here would re-parse every
                // future feed message for the life of the app, once per thread opened.
                collectors.add(scope.launch {
                    client.messages.collect { msg ->
                        try {
                            val parsed = json.parseToJsonElement(msg).jsonArray
                            if (parsed.size >= 3 && parsed[0].jsonPrimitive.contentOrNull == "EVENT") {
                                val eventObj = parsed[2].jsonObject
                                val eventId = eventObj["id"]?.jsonPrimitive?.contentOrNull
                                if (eventId == id) {
                                    val pubkey = eventObj["pubkey"]?.jsonPrimitive?.contentOrNull ?: return@collect
                                    val content = eventObj["content"]?.jsonPrimitive?.contentOrNull ?: ""
                                    val tags = eventObj["tags"]?.jsonArray?.map { t -> t.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" } } ?: emptyList()
                                    val createdAt = eventObj["created_at"]?.jsonPrimitive?.longOrNull ?: return@collect
                                    val kind = eventObj["kind"]?.jsonPrimitive?.intOrNull ?: return@collect

                                    val note = FeedNote.fromEvent(id, pubkey, content, tags, createdAt, kind)
                                    withContext(Dispatchers.Main.immediate) {
                                        var updated = _parentNotesCache.value + (id to note)
                                        if (updated.size > 500) {
                                            val referencedIds = _notes.value.mapNotNull { it.parentEventId }.toSet()
                                            updated = updated.filter { it.key in referencedIds }
                                        }
                                        _parentNotesCache.value = updated
                                    }
                                }
                            }
                        } catch (_: Exception) {}
                    }
                })

                client.send("[\"REQ\",\"$subId\",$filter]")
            }

            delay(NOTE_FETCH_TIMEOUT_MS)
            collectors.forEach { it.cancel() }
            tempClients.forEach { it.disconnect() }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Popular feed
    // ══════════════════════════════════════════════════════════════════

    private fun loadPopularFeed() {
        _isLoadingPopular.value = true
        _connectionStatus.value = "Computing popular..."

        scope.launch(Dispatchers.Default) {
            try {
                val resultJson = HavenBridge.computePopularNotes()
                if (resultJson.isNullOrEmpty()) {
                    withContext(Dispatchers.Main.immediate) {
                        _isLoadingPopular.value = false
                        _connectionStatus.value = "No popular notes"
                    }
                    return@launch
                }

                val results = json.decodeFromString<List<PopularNoteResult>>(resultJson)
                val notes = results.mapNotNull { r ->
                    FeedNote.fromEvent(r.id, r.pubkey, r.content, r.tags, r.createdAt, r.kind)
                        .takeIf { !it.isNoiseOrSpam() }
                }
                val scores = results.associate { it.id to it.score }

                withContext(Dispatchers.Main.immediate) {
                    _notes.value = notes
                    _popularNoteScores.value = scores
                    _isLoadingPopular.value = false
                    _connectionStatus.value = if (notes.isNotEmpty()) "Popular" else "No popular notes"
                    recomputeFilteredNotes()
                }
            } catch (e: Exception) {
                Log.w(TAG, "Popular feed failed: ${e.message}")
                withContext(Dispatchers.Main.immediate) {
                    _isLoadingPopular.value = false
                    _connectionStatus.value = "Popular feed error"
                }
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Search
    // ══════════════════════════════════════════════════════════════════

    fun searchDebounced(query: String) {
        _searchQuery.value = query
        searchDebounceJob?.cancel()
        if (query.isBlank()) {
            clearSearch()
            return
        }
        searchDebounceJob = scope.launch {
            delay(SEARCH_DEBOUNCE_MS)
            performSearch(query)
        }
    }

    fun performSearch(query: String) {
        _isSearching.value = true
        _isSearchActive.value = true

        nostrService.globalSearch(query) { results ->
            val feedNotes = results.notes
            _searchResults.value = feedNotes
            _isSearching.value = false
        }
    }

    fun clearSearch() {
        _isSearchActive.value = false
        _searchQuery.value = ""
        _searchResults.value = emptyList()
        _isSearching.value = false
        nostrService.cancelGlobalSearch()
    }

    // ══════════════════════════════════════════════════════════════════
    // Engagement
    // ══════════════════════════════════════════════════════════════════

    fun saveInteractionState() {
        val now = System.currentTimeMillis()
        if (now - lastInteractionSaveTime < INTERACTION_SAVE_THROTTLE_MS) return
        lastInteractionSaveTime = now

        interactionSaveJob?.cancel()
        interactionSaveJob = scope.launch(Dispatchers.IO) {
            val key = currentSnapshotKey()
            engagementTracker.saveInteractionState(
                likedEventIds = _likedEventIds.value,
                zappedEventIds = _zappedEventIds.value,
                forKey = key,
            )
        }
    }

    fun fetchNoteStats(noteId: String) {
        scope.launch(Dispatchers.IO) {
            // Connect to local + inbox relays and query for engagement
            val config = configStore.config.value
            val relayUrls = buildList {
                config.nostrURL?.let { add(it) }
                config.localInboxURL?.let { add(it) }
                config.inboxRelays?.let { addAll(it.take(1)) }
            }

            val stats = NoteStats()
            val seenReactions = mutableSetOf<String>()
            val seenReposts = mutableSetOf<String>()
            val seenZaps = mutableSetOf<String>()

            for (relayUrl in relayUrls) {
                val client = WebSocketClient(url = relayUrl, scope = scope, trustLocalhost = relayUrl.contains("localhost") || relayUrl.contains("127.0.0.1"))
                val subId = "stats-${UUID.randomUUID().toString().take(8)}"

                val collectedStats = NoteStats()

                scope.launch {
                    client.messages.collect { msg ->
                        try {
                            val parsed = json.parseToJsonElement(msg).jsonArray
                            if (parsed.size >= 3 && parsed[0].jsonPrimitive.contentOrNull == "EVENT") {
                                val eventObj = parsed[2].jsonObject
                                val id = eventObj["id"]?.jsonPrimitive?.contentOrNull ?: return@collect
                                val kind = eventObj["kind"]?.jsonPrimitive?.intOrNull ?: return@collect

                                when (kind) {
                                    6 -> if (seenReposts.add(id)) collectedStats.repostCount++
                                    7 -> if (seenReactions.add(id)) collectedStats.reactionCount++
                                    9735 -> if (seenZaps.add(id)) {
                                        collectedStats.zapCount++
                                        // Parse zap amount
                                        val tags = eventObj["tags"]?.jsonArray?.map { t -> t.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" } } ?: emptyList()
                                        val bolt11 = tags.firstOrNull { it.size >= 2 && it[0] == "bolt11" }?.get(1)
                                        // Amount parsing handled elsewhere
                                    }
                                }
                            }
                        } catch (_: Exception) {}
                    }
                }

                client.connect()

                val repostFilter = """{"kinds":[6],"#e":["$noteId"]}"""
                val reactionFilter = """{"kinds":[7],"#e":["$noteId"]}"""
                val zapFilter = """{"kinds":[9735],"#e":["$noteId"]}"""
                client.send("[\"REQ\",\"$subId-r\",$repostFilter]")
                client.send("[\"REQ\",\"$subId-l\",$reactionFilter]")
                client.send("[\"REQ\",\"$subId-z\",$zapFilter]")

                delay(NOTE_FETCH_TIMEOUT_MS)
                client.disconnect()
            }

            withContext(Dispatchers.Main.immediate) {
                val merged = NoteStats(
                    repostCount = seenReposts.size,
                    reactionCount = seenReactions.size,
                    zapCount = seenZaps.size,
                )
                _noteStats.value = _noteStats.value + (noteId to merged)
            }
        }
    }

    /** Fetch detailed engagement data (who reacted, zapped, reposted) for a single note. */
    fun fetchEngagementDetails(noteId: String, callback: (EngagementDetails) -> Unit) {
        scope.launch(Dispatchers.IO) {
            val config = configStore.config.value
            val relayUrls = buildList {
                config.nostrURL?.let { add(it) }
                config.localInboxURL?.let { add(it) }
                config.inboxRelays?.let { addAll(it.take(1)) }
            }

            val seenIds = mutableSetOf<String>()
            val reactions = mutableListOf<ReactionDetail>()
            val zaps = mutableListOf<ZapDetail>()
            val reposts = mutableListOf<RepostDetail>()

            for (relayUrl in relayUrls) {
                val client = WebSocketClient(url = relayUrl, scope = scope, trustLocalhost = relayUrl.contains("localhost") || relayUrl.contains("127.0.0.1"))
                val subId = "eng-${UUID.randomUUID().toString().take(8)}"

                scope.launch {
                    client.messages.collect { msg ->
                        try {
                            val parsed = json.parseToJsonElement(msg).jsonArray
                            if (parsed.size >= 3 && parsed[0].jsonPrimitive.contentOrNull == "EVENT") {
                                val eventObj = parsed[2].jsonObject
                                val id = eventObj["id"]?.jsonPrimitive?.contentOrNull ?: return@collect
                                if (!seenIds.add(id)) return@collect
                                val kind = eventObj["kind"]?.jsonPrimitive?.intOrNull ?: return@collect
                                val pubkey = eventObj["pubkey"]?.jsonPrimitive?.contentOrNull ?: return@collect
                                val content = eventObj["content"]?.jsonPrimitive?.contentOrNull ?: ""
                                val tags = eventObj["tags"]?.jsonArray?.map { t ->
                                    t.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" }
                                } ?: emptyList()

                                when (kind) {
                                    7 -> {
                                        val emoji = if (content == "+" || content.isBlank()) "\u2764\uFE0F" else content
                                        synchronized(reactions) { reactions.add(ReactionDetail(id, pubkey, emoji)) }
                                    }
                                    9735 -> {
                                        val descTag = tags.firstOrNull { it.size >= 2 && it[0] == "description" }?.get(1)
                                        var zapperPubkey = pubkey
                                        var amountSats = 0L
                                        var comment = ""
                                        if (descTag != null) {
                                            try {
                                                val zapReq = json.parseToJsonElement(descTag).jsonObject
                                                zapperPubkey = zapReq["pubkey"]?.jsonPrimitive?.contentOrNull ?: pubkey
                                                comment = zapReq["content"]?.jsonPrimitive?.contentOrNull ?: ""
                                                val zapTags = zapReq["tags"]?.jsonArray?.map { t ->
                                                    t.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" }
                                                } ?: emptyList()
                                                val amountTag = zapTags.firstOrNull { it.size >= 2 && it[0] == "amount" }
                                                if (amountTag != null) {
                                                    amountSats = (amountTag[1].toLongOrNull() ?: 0L) / 1000
                                                }
                                            } catch (_: Exception) {}
                                        }
                                        synchronized(zaps) { zaps.add(ZapDetail(id, zapperPubkey, amountSats, comment)) }
                                    }
                                    6 -> {
                                        synchronized(reposts) { reposts.add(RepostDetail(id, pubkey)) }
                                    }
                                }
                            }
                        } catch (_: Exception) {}
                    }
                }

                client.connect()
                val filter = """{"kinds":[6,7,9735],"#e":["$noteId"]}"""
                client.send("[\"REQ\",\"$subId\",$filter]")
                delay(NOTE_FETCH_TIMEOUT_MS)
                client.disconnect()
            }

            val allPubkeys = (reactions.map { it.pubkey } + zaps.map { it.zapperPubkey } + reposts.map { it.pubkey }).distinct()
            if (allPubkeys.isNotEmpty()) {
                nostrService.fetchMissingProfiles(allPubkeys)
            }

            val result = EngagementDetails(
                reactions = reactions.toList(),
                zaps = zaps.sortedByDescending { it.amountSats },
                reposts = reposts.distinctBy { it.pubkey },
            )
            withContext(Dispatchers.Main.immediate) { callback(result) }
        }
    }

    /** Fetch engagement details for multiple notes at once (thread-wide stats). */
    fun fetchThreadEngagement(noteIds: List<String>, callback: (Map<String, EngagementDetails>) -> Unit) {
        if (noteIds.isEmpty()) { callback(emptyMap()); return }
        scope.launch(Dispatchers.IO) {
            val config = configStore.config.value
            val relayUrls = buildList {
                config.nostrURL?.let { add(it) }
                config.localInboxURL?.let { add(it) }
                config.inboxRelays?.let { addAll(it.take(1)) }
            }

            val seenIds = mutableSetOf<String>()
            val noteIdSet = noteIds.toSet()
            val perNote = ConcurrentHashMap<String, MutableList<Any>>()

            for (relayUrl in relayUrls) {
                val client = WebSocketClient(url = relayUrl, scope = scope, trustLocalhost = relayUrl.contains("localhost") || relayUrl.contains("127.0.0.1"))
                val subId = "thr-${UUID.randomUUID().toString().take(8)}"

                scope.launch {
                    client.messages.collect { msg ->
                        try {
                            val parsed = json.parseToJsonElement(msg).jsonArray
                            if (parsed.size >= 3 && parsed[0].jsonPrimitive.contentOrNull == "EVENT") {
                                val eventObj = parsed[2].jsonObject
                                val id = eventObj["id"]?.jsonPrimitive?.contentOrNull ?: return@collect
                                if (!seenIds.add(id)) return@collect
                                val kind = eventObj["kind"]?.jsonPrimitive?.intOrNull ?: return@collect
                                val pubkey = eventObj["pubkey"]?.jsonPrimitive?.contentOrNull ?: return@collect
                                val content = eventObj["content"]?.jsonPrimitive?.contentOrNull ?: ""
                                val tags = eventObj["tags"]?.jsonArray?.map { t ->
                                    t.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" }
                                } ?: emptyList()

                                val targetNoteId = tags.firstOrNull { it.size >= 2 && it[0] == "e" && it[1] in noteIdSet }?.get(1) ?: return@collect

                                val detail: Any = when (kind) {
                                    7 -> {
                                        val emoji = if (content == "+" || content.isBlank()) "\u2764\uFE0F" else content
                                        ReactionDetail(id, pubkey, emoji)
                                    }
                                    9735 -> {
                                        val descTag = tags.firstOrNull { it.size >= 2 && it[0] == "description" }?.get(1)
                                        var zapperPubkey = pubkey
                                        var amountSats = 0L
                                        var comment = ""
                                        if (descTag != null) {
                                            try {
                                                val zapReq = json.parseToJsonElement(descTag).jsonObject
                                                zapperPubkey = zapReq["pubkey"]?.jsonPrimitive?.contentOrNull ?: pubkey
                                                comment = zapReq["content"]?.jsonPrimitive?.contentOrNull ?: ""
                                                val zapTags = zapReq["tags"]?.jsonArray?.map { t ->
                                                    t.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" }
                                                } ?: emptyList()
                                                val amountTag = zapTags.firstOrNull { it.size >= 2 && it[0] == "amount" }
                                                if (amountTag != null) {
                                                    amountSats = (amountTag[1].toLongOrNull() ?: 0L) / 1000
                                                }
                                            } catch (_: Exception) {}
                                        }
                                        ZapDetail(id, zapperPubkey, amountSats, comment)
                                    }
                                    6 -> RepostDetail(id, pubkey)
                                    else -> return@collect
                                }
                                perNote.getOrPut(targetNoteId) { mutableListOf() }.add(detail)
                            }
                        } catch (_: Exception) {}
                    }
                }

                client.connect()
                val noteIdsJson = noteIds.joinToString(",") { "\"$it\"" }
                val filter = """{"kinds":[6,7,9735],"#e":[$noteIdsJson],"limit":500}"""
                client.send("[\"REQ\",\"$subId\",$filter]")
                delay(NOTE_FETCH_TIMEOUT_MS)
                client.disconnect()
            }

            val result = perNote.mapValues { (_, details) ->
                EngagementDetails(
                    reactions = details.filterIsInstance<ReactionDetail>(),
                    zaps = details.filterIsInstance<ZapDetail>().sortedByDescending { it.amountSats },
                    reposts = details.filterIsInstance<RepostDetail>().distinctBy { it.pubkey },
                )
            }
            withContext(Dispatchers.Main.immediate) { callback(result) }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Snapshots
    // ══════════════════════════════════════════════════════════════════

    fun currentSnapshotKey(): String {
        return configStore.config.value.activeAccountNpub ?: "owner"
    }

    fun persistCurrentSnapshot() {
        scope.launch(Dispatchers.IO) {
            val key = currentSnapshotKey()
            val newestTimestamp = _notes.value.firstOrNull()?.createdAt?.time?.div(1000) ?: 0L
            val snapshot = DiskFeedSnapshot(
                notes = _notes.value.take(SNAPSHOT_MAX_NOTES),
                followedPubkeys = _followedPubkeys.value,
                noteStats = _noteStats.value,
                contactListContent = contactListContent,
                likedEventIds = _likedEventIds.value,
                zappedEventIds = _zappedEventIds.value,
                savedAt = System.currentTimeMillis(),
                lastEventTimestamp = newestTimestamp,
                scrollIndex = _savedScrollIndex,
                scrollOffset = _savedScrollOffset,
            )

            try {
                val dir = configStore.config.value.appSupportDir ?: return@launch
                val file = File(dir, "feed_snapshot_$key.json")
                file.writeText(json.encodeToString(DiskFeedSnapshot.serializer(), snapshot))
            } catch (e: Exception) {
                Log.w(TAG, "Snapshot save failed: ${e.message}")
            }
        }
    }

    private suspend fun restoreFromDiskIfAvailable(): Boolean {
        return withContext(Dispatchers.IO) {
            try {
                val key = currentSnapshotKey()
                val dir = configStore.config.value.appSupportDir ?: return@withContext false
                val file = File(dir, "feed_snapshot_$key.json")
                if (!file.exists()) return@withContext false

                val content = file.readText()
                val snapshot = json.decodeFromString(DiskFeedSnapshot.serializer(), content)

                // Check age
                if (System.currentTimeMillis() - snapshot.savedAt > SNAPSHOT_MAX_AGE_MS) {
                    file.delete()
                    return@withContext false
                }

                // Populate seenIds from restored notes to prevent duplicates on top-up
                seenIdsLock.withLock {
                    for (note in snapshot.notes) {
                        seenIds.add(note.id)
                    }
                }

                withContext(Dispatchers.Main.immediate) {
                    _notes.value = snapshot.notes
                    _followedPubkeys.value = snapshot.followedPubkeys
                    _noteStats.value = snapshot.noteStats
                    contactListContent = snapshot.contactListContent
                    _likedEventIds.value = snapshot.likedEventIds
                    _zappedEventIds.value = snapshot.zappedEventIds
                    _hasAttemptedContactLoad.value = true

                    // Restore scroll position so the feed opens where the user left off
                    if (snapshot.scrollIndex > 0) {
                        _restoredScrollPosition.value = ScrollPosition(
                            snapshot.scrollIndex,
                            snapshot.scrollOffset,
                        )
                    }

                    // Warm avatar memory cache before UI renders the list
                    prewarmAvatarCache(snapshot.notes)

                    recomputeFilteredNotes()
                }

                true
            } catch (e: Exception) {
                Log.w(TAG, "Snapshot restore failed: ${e.message}")
                false
            }
        }
    }

    /**
     * Pre-warm Coil's memory cache for avatar images of the first visible notes.
     * Loads from disk cache → memory so avatars render instantly without the
     * gradient-fallback flash on resume.
     */
    private fun prewarmAvatarCache(notes: List<FeedNote>) {
        val profiles = nostrService.profiles.value
        val subset = notes.take(AVATAR_PREWARM_COUNT)
        val urls = subset
            .flatMap { note ->
                listOfNotNull(
                    profiles[note.repostedBy ?: note.pubkey]?.pictureURL,
                    note.replyToPubkey?.let { profiles[it]?.pictureURL },
                )
            }
            .distinct()
            .filter { url ->
                val key = coil.memory.MemoryCache.Key(url)
                imageLoader.memoryCache?.get(key) == null
            }

        if (urls.isEmpty()) return
        Log.d(TAG, "Pre-warming ${urls.size} avatar(s) into memory cache")

        scope.launch(Dispatchers.IO) {
            coroutineScope {
                urls.map { url ->
                    async {
                        try {
                            val request = ImageRequest.Builder(appContext)
                                .data(url)
                                .size(128)
                                .memoryCachePolicy(CachePolicy.ENABLED)
                                .diskCachePolicy(CachePolicy.ENABLED)
                                .allowHardware(true)
                                .build()
                            imageLoader.execute(request)
                        } catch (_: Exception) { /* best-effort */ }
                    }
                }.awaitAll()
            }
        }
    }

    private fun topUpFromRelays() {
        _isSyncing.value = true
        _connectionStatus.value = "Syncing..."

        // Subscribe to relays immediately (background sync)
        subscribeToAllRelays()

        // Load contacts in background (doesn't block visible feed)
        scope.launch { loadContactList() }
    }

    private fun clearInMemoryFeedState() {
        _notes.value = emptyList()
        _pendingNotes.value = emptyList()
        _noteStats.value = emptyMap()
        _newNoteCount.value = 0
        seenIdsLock.withLock { seenIds.clear() }
        rawEventCache.clear()
        recomputeFilteredNotes()
    }

    // ══════════════════════════════════════════════════════════════════
    // Local relay operations
    // ══════════════════════════════════════════════════════════════════

    fun addLocalRelayIfReady() {
        val config = configStore.config.value
        val localUrl = config.nostrURL ?: return
        if (feedClients.containsKey(localUrl)) return
        connectFeedRelay(localUrl)
    }

    fun sendToLocalRelay(text: String): Boolean {
        val config = configStore.config.value
        val localUrl = config.nostrURL ?: return false
        val client = feedClients[localUrl] ?: return false
        client.send(text)
        return true
    }

    // ══════════════════════════════════════════════════════════════════
    // Cache management
    // ══════════════════════════════════════════════════════════════════

    fun cacheRawEvent(id: String, eventJson: String) {
        rawEventCache[id] = eventJson
    }

    fun getCachedRawEvent(id: String): String? = rawEventCache[id]

    // ══════════════════════════════════════════════════════════════════
    // ViewModel convenience methods (aliases)
    // ══════════════════════════════════════════════════════════════════

    /** Alias for switchMode(), used by FeedViewModel. */
    fun switchFeedMode(mode: FeedMode) = switchMode(mode)

    /** Alias for loadMore(), used by FeedViewModel. */
    fun loadOlderNotes() = loadMore()

    /** Like a note (kind 7 reaction). */
    fun likeNote(noteId: String, emoji: String? = null) {
        val existing = _likedEventIds.value
        if (noteId in existing) return
        _likedEventIds.value = existing + noteId

        val reactionEmoji = emoji ?: configStore.config.value.defaultReactionEmoji

        scope.launch(Dispatchers.IO) {
            val tags = listOf(listOf("e", noteId))
            val event = nostrService.signEvent(kind = 7, content = reactionEmoji, tags = tags)
            event?.let { nostrService.postEvent(it) }
        }

        val stats = _noteStats.value.toMutableMap()
        val existing2 = stats[noteId] ?: NoteStats()
        stats[noteId] = existing2.copy(reactionCount = existing2.reactionCount + 1)
        _noteStats.value = stats
    }

    /** Remove a like (used by undo-unlike countdown). */
    fun unlikeNote(noteId: String) {
        _likedEventIds.value = _likedEventIds.value - noteId
        val stats = _noteStats.value.toMutableMap()
        val existing = stats[noteId] ?: NoteStats()
        stats[noteId] = existing.copy(reactionCount = maxOf(0, existing.reactionCount - 1))
        _noteStats.value = stats
        saveInteractionState()
    }

    /** Repost a note (kind 6). */
    fun repostNote(noteId: String) {
        val existing = _repostedEventIds.value
        if (noteId in existing) return
        _repostedEventIds.value = existing + noteId

        scope.launch(Dispatchers.IO) {
            val rawEvent = rawEventCache[noteId] ?: ""
            val tags = listOf(listOf("e", noteId))
            val event = nostrService.signEvent(kind = 6, content = rawEvent, tags = tags)
            event?.let { nostrService.postEvent(it) }
        }

        val stats = _noteStats.value.toMutableMap()
        val existing2 = stats[noteId] ?: NoteStats()
        stats[noteId] = existing2.copy(repostCount = existing2.repostCount + 1)
        _noteStats.value = stats
    }

    /** Zap a note (placeholder — full zap flow requires LNURL). */
    fun zapNote(noteId: String, amount: Long) {
        val existing = _zappedEventIds.value.toMutableMap()
        existing[noteId] = (existing[noteId] ?: 0) + amount.toInt()
        _zappedEventIds.value = existing

        val stats = _noteStats.value.toMutableMap()
        val existing2 = stats[noteId] ?: NoteStats()
        stats[noteId] = existing2.copy(
            zapCount = existing2.zapCount + 1,
            zapAmountSats = existing2.zapAmountSats + amount,
        )
        _noteStats.value = stats
    }

    fun injectExternalEvent(eventJson: String, eventId: String) {
        if (!injectedEventIds.add(eventId)) return
        if (injectedEventIds.size > MAX_INJECTED_IDS) {
            injectedEventIds.clear()
        }

        val config = configStore.config.value
        val inboxUrl = config.localInboxURL ?: return

        scope.launch(Dispatchers.IO) {
            val client = WebSocketClient(url = inboxUrl, scope = scope, trustLocalhost = true)
            client.connect()
            client.send("[\"EVENT\",$eventJson]")
            delay(300)
            client.disconnect()
        }
    }
}

// ── Scroll position ───────────────────────────────────────────────

data class ScrollPosition(val index: Int, val offset: Int)

// ── Error types ───────────────────────────────────────────────────

sealed class FollowActionError : Exception() {
    data object ContactsNotLoaded : FollowActionError()
    data object SafetyCheckFailed : FollowActionError()
    data object AlreadyFollowing : FollowActionError()
    data object NotFollowing : FollowActionError()
}

// ── Disk snapshot ─────────────────────────────────────────────────

@kotlinx.serialization.Serializable
data class DiskFeedSnapshot(
    val notes: List<FeedNote>,
    val followedPubkeys: List<String>,
    val noteStats: Map<String, NoteStats>,
    val contactListContent: String,
    val likedEventIds: Set<String>,
    val zappedEventIds: Map<String, Int>,
    val savedAt: Long,
    val lastEventTimestamp: Long = 0L,
    val scrollIndex: Int = 0,
    val scrollOffset: Int = 0,
)

// AccumulatorBatch replaced by BackgroundAccumulator.Snapshot in FeedServiceTypes.kt
