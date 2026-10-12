package com.nostrvault.service

import com.nostrvault.data.model.TrustMap
import android.content.Context
import android.os.FileObserver
import android.util.Log
import coil.ImageLoader
import coil.request.CachePolicy
import coil.request.ImageRequest
import com.nostrvault.BuildConfig
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.BlobNoteIndexStore
import com.nostrvault.data.local.EngagementTracker
import com.nostrvault.data.model.*
import com.nostrvault.data.remote.LookupSocketPool
import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.HavenConfig
import com.nostrvault.ui.notification.FollowKind
import com.nostrvault.ui.notification.NotificationManager
import com.nostrvault.ui.components.ReactionChoice
import com.nostrvault.ui.components.likedToastMessage
import com.nostrvault.util.RelayGiven
import com.nostrvault.util.ZapAmount
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
    @ApplicationContext internal val appContext: Context,
    internal val configStore: ConfigStore,
    internal val nostrService: NostrService,
    internal val feedFilterEngine: FeedFilterEngine,
    internal val engagementTracker: EngagementTracker,
    private val blobNoteIndexStore: BlobNoteIndexStore,
    internal val contactManager: ContactManager,
    internal val imageLoader: ImageLoader,
    internal val notificationManager: NotificationManager,
    internal val followingBackupService: FollowingBackupService,
    internal val lookupPool: LookupSocketPool,
) {
    companion object {
        /** The relay writes this into its data root (haven-go WOT_CACHE_PATH default). */
        internal const val WOT_CACHE_FILE = "wot_cache.json"
        internal const val TAG = "FeedService"
        // High bound so the user can scroll back through effectively their whole
        // history (lazy list virtualizes rendering; only a ceiling vs runaway memory).
        internal const val MAX_FEED_NOTES = 10_000
        internal const val MAX_PENDING_NOTES = 200
        internal const val MAX_RAW_EVENT_CACHE = 1000
        internal const val MAX_INJECTED_IDS = 10_000
        internal const val CONTACT_LOAD_TIMEOUT_MS = 15_000L
        // After the first kind-3 arrives, wait briefly for a newer version from
        // another relay before committing (kind-3 is replaceable → newest wins).
        internal const val CONTACT_NEWEST_GRACE_MS = 1_200L
        internal const val FEED_LOAD_TIMEOUT_MS = 20_000L
        internal const val EXTENDED_NETWORK_TIMEOUT_MS = 15_000L
        internal const val NOTE_FETCH_TIMEOUT_MS = 8_000L
        private const val NOTE_FETCH_BATCH_DELAY_MS = 300L
        private const val UNAVAILABLE_RETRY_MS = 60_000L
        /** Quiet time after a batch of follows' relay lists before re-planning. */
        private const val OUTBOX_RELAY_LIST_SETTLE_MS = 5_000L
        /** Failed connects in a row before a feed relay counts as down. */
        internal const val FEED_RELAY_DOWN_AFTER = 3

        /**
         * Asked on the second pass, for referenced notes neither your relays
         * nor the author's carry. Same list as iOS FeedService.fallbackNoteRelays,
         * picked by measurement on 2026-10-01; re-measure with
         * `.scratch/roots/probe5.py` in the Buzz nest before changing it.
         * offchain.pub refused connections on 2026-10-12 and was dropped.
         */
        internal val FALLBACK_NOTE_RELAYS = listOf(
            "wss://nostr.wine",
            "wss://nostr.oxtr.dev",
            "wss://nostr.land",
            "wss://relay.nostrplebs.com",
            "wss://relay.snort.social",
            "wss://relay.primal.net",
            "wss://relay.damus.io",
        )
        private const val SEARCH_TIMEOUT_MS = 10_000L
        private const val SEARCH_DEBOUNCE_MS = 400L
        internal const val INTERACTION_SAVE_THROTTLE_MS = 2_000L
        internal const val FLUSH_INTERVAL_STANDARD_MS = 800L
        internal const val FLUSH_INTERVAL_GLOBAL_MS = 50L
        // Longest a batch waits for a drag or fling to settle. Past this it
        // lands anyway, so a long slow drag still sees new pages.
        internal const val SCROLL_FLUSH_HOLD_MS = 1_500L
        internal const val PARENT_CACHE_MAX = 500
        internal const val PARENT_CACHE_TRIM_TO = 400
        private const val NOTE_BATCH_DELAY_MS = 150L
        internal const val STAGGER_RELAY_MS = 200L
        internal const val SNAPSHOT_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000L // 7 days (matches iOS)
        internal const val SNAPSHOT_MAX_NOTES = 200
        internal const val EXTENDED_NETWORK_CACHE_MS = 60 * 60 * 1000L // 1 hour
        // A tally missing a relay's answers is held briefly rather than for the
        // full hour — see loadExtendedNetwork.
        internal const val PARTIAL_EXTENDED_NETWORK_CACHE_MS = 5 * 60 * 1000L // 5 minutes
        // Follows per kind-3 REQ. Matches iOS fetchExtendedNetworkInParallel.
        internal const val EXTENDED_NETWORK_CHUNK = 200
        internal const val MAX_SEEN_IDS = 10_000
        internal const val RECOMPUTE_DEBOUNCE_MS = 50L
        /** Global's stream batches land every 50 ms; gather them into one reply fetch. */
        internal const val THREAD_REPLIES_SETTLE_MS = 500L
        internal const val AVATAR_PREWARM_COUNT = 80 // Warm cache for ~4 screens of visible notes
    }

    internal val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    internal val processingDispatcher = Dispatchers.Default
    internal val json = Json { ignoreUnknownKeys = true }

    // ── Observable state ──────────────────────────────────────────────

    internal val _feedMode = MutableStateFlow(
        configStore.config.value.defaultFeedMode
            .let { name -> FeedMode.entries.find { it.name == name } }
            ?: FeedMode.FOLLOWING
    )
    val feedMode: StateFlow<FeedMode> = _feedMode.asStateFlow()

    internal val _mediaFeedMode = MutableStateFlow(MediaFeedMode.FOLLOWING)
    val mediaFeedMode: StateFlow<MediaFeedMode> = _mediaFeedMode.asStateFlow()

    /**
     * Following / Global for Articles and Recipes (iOS parity). Global follows
     * the app-wide Web of Trust shield like every Global view.
     */
    internal val _articlesFeedMode = MutableStateFlow(MediaFeedMode.FOLLOWING)
    val articlesFeedMode: StateFlow<MediaFeedMode> = _articlesFeedMode.asStateFlow()
    internal val _recipesFeedMode = MutableStateFlow(MediaFeedMode.FOLLOWING)
    val recipesFeedMode: StateFlow<MediaFeedMode> = _recipesFeedMode.asStateFlow()
    /** Polls' Following / Global, scoped the same way as Articles. */
    internal val _pollsFeedMode = MutableStateFlow(MediaFeedMode.FOLLOWING)
    val pollsFeedMode: StateFlow<MediaFeedMode> = _pollsFeedMode.asStateFlow()
    /** Polls' Open / Closed / All filter. */
    internal val _pollStatusFilter = MutableStateFlow(com.nostrvault.data.model.PollStatusFilter.ALL)
    val pollStatusFilter: StateFlow<com.nostrvault.data.model.PollStatusFilter> = _pollStatusFilter.asStateFlow()

    /**
     * The one rule every Global view follows: your Web of Trust unless the
     * shield is set to Everyone. Null means everyone. Fails closed like the
     * Global feed: with no graph yet, nobody passes.
     */
    /**
     * Who counts as inside your network in the Relay tab: the relay's trust
     * graph plus your current follows. The graph is rebuilt about once a day,
     * so without the follows someone you just followed stayed "outside".
     * Empty while the graph isn't loaded, which counts nobody as outside.
     */
    fun relayTabTrustedPubkeys(): Set<String> {
        if (_wotPubkeys.value.isEmpty()) loadWotPubkeys()
        return TrustMap.web(_wotPubkeys.value, _followedPubkeys.value.toSet())
    }

    fun globalTrustSet(): Set<String>? {
        if (configStore.config.value.globalShowsEveryone) return null
        if (_wotPubkeys.value.isEmpty()) loadWotPubkeys()
        // Your follows too, so someone you just followed passes right away.
        return TrustMap.web(_wotPubkeys.value, _followedPubkeys.value.toSet())
    }

    internal val _notes = MutableStateFlow<List<FeedNote>>(emptyList())
    val notes: StateFlow<List<FeedNote>> = _notes.asStateFlow()

    // Periodic disk-snapshot persistence (crash safety). Persisting only in
    // pauseFeed() loses the whole session when the process is killed without a
    // lifecycle callback; persist at most once a minute while the feed changes.
    private var snapshotDirty = false

    /**
     * hash → note id for every blob this device has seen a note reference.
     *
     * Exposed here because the media gallery already holds this service, and
     * because the thing that fills the index is the note stream this service
     * owns. Reading it is what stops "Open Note" on a blob from depending on
     * how far the feed happened to be scrolled — see [BlobNoteIndexStore].
     */
    val blobNoteIndex: StateFlow<Map<String, String>> = blobNoteIndexStore.index

    init {
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

    internal val _filteredNotes = MutableStateFlow<List<FeedNote>>(emptyList())
    val filteredNotes: StateFlow<List<FeedNote>> = _filteredNotes.asStateFlow()

    internal val _filteredMediaNotes = MutableStateFlow<List<FeedNote>>(emptyList())
    val filteredMediaNotes: StateFlow<List<FeedNote>> = _filteredMediaNotes.asStateFlow()

    internal val _parentNotesCache = MutableStateFlow<Map<String, FeedNote>>(emptyMap())
    val parentNotesCache: StateFlow<Map<String, FeedNote>> = _parentNotesCache.asStateFlow()

    /**
     * Quoted addressable events (long-form articles, live streams), keyed by
     * their `naddr:<kind>:<pubkey>:<d>` coordinate.
     *
     * Separate from [_parentNotesCache] because these are not addressed by id:
     * an article is edited in place, so the coordinate is stable while the id
     * of the newest revision is not.
     */
    internal val _quotedAddressCache = MutableStateFlow<Map<String, FeedNote>>(emptyMap())

    /**
     * Every fetched quoted event, keyed by the lookup key its quoting note
     * holds — a hex id or an `naddr:` coordinate, whichever is in
     * `FeedNote.quotedEventIds`.
     *
     * Screens observe this one map rather than the two caches behind it, so a
     * card cannot be looked up by a key the fetcher never stored under, and a
     * screen cannot miss the arrival of a quoted article by watching only the
     * by-id cache.
     */
    val quotedNotes: StateFlow<Map<String, FeedNote>> =
        combine(_parentNotesCache, _quotedAddressCache) { byId, byAddress -> byId + byAddress }
            .stateIn(scope, SharingStarted.Eagerly, emptyMap())

    internal val _followedPubkeys = MutableStateFlow<List<String>>(emptyList())
    val followedPubkeys: StateFlow<List<String>> = _followedPubkeys.asStateFlow()

    internal val _extendedNetworkPubkeys = MutableStateFlow<List<String>>(emptyList())
    val extendedNetworkPubkeys: StateFlow<List<String>> = _extendedNetworkPubkeys.asStateFlow()

    internal val _isLoadingContacts = MutableStateFlow(false)
    val isLoadingContacts: StateFlow<Boolean> = _isLoadingContacts.asStateFlow()

    internal val _isLoadingExtendedNetwork = MutableStateFlow(false)
    val isLoadingExtendedNetwork: StateFlow<Boolean> = _isLoadingExtendedNetwork.asStateFlow()

    internal val _hasAttemptedContactLoad = MutableStateFlow(false)
    val hasAttemptedContactLoad: StateFlow<Boolean> = _hasAttemptedContactLoad.asStateFlow()

    internal val _isLoadingFeed = MutableStateFlow(false)
    val isLoadingFeed: StateFlow<Boolean> = _isLoadingFeed.asStateFlow()

    internal val _isLoadingPopular = MutableStateFlow(false)
    val isLoadingPopular: StateFlow<Boolean> = _isLoadingPopular.asStateFlow()

    internal val _isSyncing = MutableStateFlow(false)
    val isSyncing: StateFlow<Boolean> = _isSyncing.asStateFlow()

    private val _feedScrollingDown = MutableStateFlow(false)
    val feedScrollingDown: StateFlow<Boolean> = _feedScrollingDown.asStateFlow()

    internal val _connectionStatus = MutableStateFlow("Disconnected")
    val connectionStatus: StateFlow<String> = _connectionStatus.asStateFlow()

    internal val _connectionColor = MutableStateFlow("gray")
    val connectionColor: StateFlow<String> = _connectionColor.asStateFlow()

    internal val _newNoteCount = MutableStateFlow(0)
    val newNoteCount: StateFlow<Int> = _newNoteCount.asStateFlow()

    internal val _pendingNotes = MutableStateFlow<List<FeedNote>>(emptyList())
    val pendingNotes: StateFlow<List<FeedNote>> = _pendingNotes.asStateFlow()

    internal val _likedEventIds = MutableStateFlow<Set<String>>(emptySet())
    val likedEventIds: StateFlow<Set<String>> = _likedEventIds.asStateFlow()

    /** The emoji (and kind-7 event) behind each entry of [likedEventIds]. */
    internal val _myReactions = MutableStateFlow<Map<String, EngagementTracker.MyReaction>>(emptyMap())
    val myReactions: StateFlow<Map<String, EngagementTracker.MyReaction>> = _myReactions.asStateFlow()

    /** Reactions this account deleted; see [EngagementTracker.InteractionState.retractedReactionIds]. Main-confined. */
    internal var retractedReactionIds: Set<String> = emptySet()

    /**
     * Per note, the reaction currently being signed. A tap that changes or
     * removes it before signing ends replaces the token, and the stale
     * reaction is then never published. Main-confined.
     */
    internal val pendingReactionTokens = HashMap<String, Any>()

    private val _repostedEventIds = MutableStateFlow<Set<String>>(emptySet())
    val repostedEventIds: StateFlow<Set<String>> = _repostedEventIds.asStateFlow()

    internal val _zappedEventIds = MutableStateFlow<Map<String, Int>>(emptyMap())
    val zappedEventIds: StateFlow<Map<String, Int>> = _zappedEventIds.asStateFlow()

    internal val _noteStats = MutableStateFlow<Map<String, NoteStats>>(emptyMap())
    val noteStats: StateFlow<Map<String, NoteStats>> = _noteStats.asStateFlow()

    internal val _isSearchActive = MutableStateFlow(false)
    val isSearchActive: StateFlow<Boolean> = _isSearchActive.asStateFlow()

    internal val _searchQuery = MutableStateFlow("")
    val searchQuery: StateFlow<String> = _searchQuery.asStateFlow()

    internal val _searchResults = MutableStateFlow<List<FeedNote>>(emptyList())
    val searchResults: StateFlow<List<FeedNote>> = _searchResults.asStateFlow()

    internal val _isSearching = MutableStateFlow(false)
    val isSearching: StateFlow<Boolean> = _isSearching.asStateFlow()

    // Saved in the config so they survive a restart, as on iOS. Read from the
    // config, not copied: the config loads from disk after this is built.
    val showReposts: StateFlow<Boolean> = configStore.config.map { it.showReposts }
        .stateIn(scope, SharingStarted.Eagerly, configStore.config.value.showReposts)

    val showReplies: StateFlow<Boolean> = configStore.config.map { it.showReplies }
        .stateIn(scope, SharingStarted.Eagerly, configStore.config.value.showReplies)

    internal val _popularFilter = MutableStateFlow(PopularFilter.ALL)
    val popularFilter: StateFlow<PopularFilter> = _popularFilter.asStateFlow()

    private val _showPopularEngagement = MutableStateFlow(true)
    val showPopularEngagement: StateFlow<Boolean> = _showPopularEngagement.asStateFlow()

    internal val _popularNoteScores = MutableStateFlow<Map<String, Double>>(emptyMap())
    val popularNoteScores: StateFlow<Map<String, Double>> = _popularNoteScores.asStateFlow()

    /**
     * Replies to the Popular and Global posts, fetched only for Threaded View,
     * by id. Kept out of [notes]: Popular lists top-level posts, and Global's
     * stream rarely carries the replies to what it shows, so without these a
     * threaded card had nothing under it. See [loadFeedThreadReplies].
     */
    internal val _feedThreadReplies = MutableStateFlow<Map<String, FeedNote>>(emptyMap())
    val feedThreadReplies: StateFlow<Map<String, FeedNote>> = _feedThreadReplies.asStateFlow()
    internal val threadRepliesLock = Any()
    /** Post ids already asked about in this list; guarded by [threadRepliesLock]. */
    internal val threadRepliesRequested = HashSet<String>()
    /** Post ids waiting for the worker; guarded by [threadRepliesLock]. */
    internal val threadRepliesPending = LinkedHashSet<String>()
    /** Null when no worker is draining [threadRepliesPending]. */
    internal var threadRepliesJob: Job? = null
    /**
     * Bumped on every reset, so a fetch that outlives its feed's list can't
     * add replies to the next one.
     */
    @Volatile internal var threadRepliesGeneration = 0

    internal val _wotPubkeys = MutableStateFlow<Set<String>>(emptySet())
    val wotPubkeys: StateFlow<Set<String>> = _wotPubkeys.asStateFlow()
    /**
     * For everyone in the graph past your follows, how many of your follows
     * follow them (the WOT tab's Close layer). Null until the relay's cache
     * carries them.
     */
    private val _wotVouches = MutableStateFlow<Map<String, Int>?>(null)
    val wotVouches: StateFlow<Map<String, Int>?> = _wotVouches.asStateFlow()

    /**
     * True once the relay's graph file has been read for this account, even
     * if it named nobody. Separates "no graph built yet" from "built and
     * empty because you follow nobody". iOS: FeedService.wotCacheRead.
     */
    private val _wotCacheRead = MutableStateFlow(false)
    val wotCacheRead: StateFlow<Boolean> = _wotCacheRead.asStateFlow()

    /**
     * The graph is built and names nobody: the account follows no one yet.
     * Global says so, and the Hashtags feed opens up (labelled) so there is
     * somewhere to find people to follow.
     */
    fun hasNoWebOfTrustYet(): Boolean = _wotCacheRead.value && _wotPubkeys.value.isEmpty()

    /**
     * Everyone around the user, for ranking search and mention results after
     * their follows: the relay's Web of Trust graph plus the extended network.
     * iOS: FeedService.webOfTrustForRanking.
     */
    fun webOfTrustForRanking(): Set<String> = _wotPubkeys.value + _extendedNetworkPubkeys.value

    internal val _parentIsNextNote = MutableStateFlow<Set<String>>(emptySet())
    val parentIsNextNote: StateFlow<Set<String>> = _parentIsNextNote.asStateFlow()

    val isInjecting = MutableStateFlow(false)

    // ── Internal state ────────────────────────────────────────────────

    internal val seenIds = LinkedHashSet<String>()
    internal val seenIdsLock = ReentrantLock()
    internal val rawEventCache = ConcurrentHashMap<String, String>()
    internal val injectedEventIds = ConcurrentHashMap.newKeySet<String>()
    internal val feedClients = ConcurrentHashMap<String, WebSocketClient>()
    // Collector Jobs per feed client (messages + connectionState). Tracked so they
    // can be cancelled on removal — client.messages is a SharedFlow that never
    // completes, so disconnect() alone leaves these coroutines (and the client)
    // pinned in memory forever.
    internal val feedClientJobs = ConcurrentHashMap<String, MutableList<Job>>()

    /**
     * Each feed relay's own socket state, keyed by [FeedRelayHealth.key]. The
     * feed dot reads this; [connectionStatus] alone only says whether the
     * feed has notes (iOS #281).
     */
    internal val _relayStates = MutableStateFlow<Map<String, WebSocketClient.ConnectionState>>(emptyMap())
    val relayStates: StateFlow<Map<String, WebSocketClient.ConnectionState>> = _relayStates.asStateFlow()
    // Relays whose auxiliary subscriptions (reactions/zaps) have been sent for the
    // current connection. Cleared on disconnect/teardown so reconnects re-send.
    internal val auxSubsSent = ConcurrentHashMap.newKeySet<String>()

    /**
     * Follows the feed relays don't reach, asked on their own write relays:
     * extra relay URL → the follows to ask it for. See [FeedOutboxPlan].
     */
    @Volatile internal var outboxPlan: Map<String, List<String>> = emptyMap()

    /**
     * Feed relays that failed to connect three times running and have not
     * connected since. Kept across load rounds, so the plan stops counting a
     * dead feed relay as reaching anyone (iOS `downRelayKeys`).
     */
    internal val downRelayUrls = ConcurrentHashMap.newKeySet<String>()
    internal val feedConnectFailures = ConcurrentHashMap<String, Int>()

    // Background accumulator
    internal val accumulator = BackgroundAccumulator()
    internal val feedScrolling = MutableStateFlow(false)
    internal val pendingInserts = ArrayList<FeedNote>()
    internal val pendingEngagement = ArrayList<BackgroundAccumulator.Snapshot>()
    internal var mergeJob: Job? = null
    internal var flushScheduled = false
    internal val flushLock = ReentrantLock()
    internal var isInitialLoad = false

    // Contact list content (for safety checks)
    internal var contactListContent: String = ""
    // created_at of the contact list we last published/committed locally. The
    // relay-fetch overwrite is only accepted when its created_at is >= this value;
    // otherwise the relay copy is older than our latest local edit (e.g. a fresh
    // follow whose publish hasn't propagated) and we keep the local set + re-publish.
    // Primed from the durable following backup (keyed per account) so it survives
    // relaunches and the feed snapshot TTL. @Volatile: written from both the main
    // thread (guard prime / sync bump) and the IO publish coroutine.
    @Volatile
    internal var ownContactListCreatedAt: Long = 0L
    /**
     * created_at of a contact list every relay refused and that was rolled
     * back. The local relay still holds it, so a reload must not take it.
     */
    @Volatile internal var refusedContactListCreatedAt: Long? = null
    // Account key `ownContactListCreatedAt` belongs to; reset across account
    // switches so a previous account's timestamp can't block the new account.
    @Volatile
    internal var ownContactListAccountKey: String = ""

    // Bumped at the start of every loadContactList() call; a call only commits its
    // result if this still matches the value it captured. loadContactList() has no
    // job-cancellation tracking, so two overlapping calls (e.g. one still in flight
    // from just before an account switch, another started right after) previously
    // had last-to-resolve win regardless of which account it actually queried for.
    @Volatile
    internal var contactLoadGeneration: Int = 0

    // Account snapshots (in-memory)
    private val accountSnapshots = ConcurrentHashMap<String, AccountFeedSnapshot>()

    // Interaction state persistence
    internal var lastInteractionSaveTime = 0L
    internal var interactionSaveJob: Job? = null
    internal var interactionSaveScheduled = false

    // Scroll position tracking for snapshot persistence
    internal var _savedScrollIndex = 0
    internal var _savedScrollOffset = 0

    internal val _restoredScrollPosition = MutableStateFlow<ScrollPosition?>(null)
    val restoredScrollPosition: StateFlow<ScrollPosition?> = _restoredScrollPosition.asStateFlow()

    // Tab re-selection scroll-to-top event
    private val _scrollToTopRequest = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val scrollToTopRequest: SharedFlow<Unit> = _scrollToTopRequest.asSharedFlow()

    // Condensed-bar relay action: open the relay dashboard sheet (iOS parity with
    // the collapsed antenna's openRelayDashboard). DashboardScreen subscribes.
    private val _relayDashboardRequest = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val relayDashboardRequest: SharedFlow<Unit> = _relayDashboardRequest.asSharedFlow()

    // Optimistic note insertion: emitted immediately when a note is signed,
    // before relay confirmation. NoteDetailViewModel subscribes to show replies inline.
    private val _optimisticNote = MutableSharedFlow<FeedNote>(extraBufferCapacity = 8)
    val optimisticNote: SharedFlow<FeedNote> = _optimisticNote.asSharedFlow()

    fun emitOptimisticNote(note: FeedNote) {
        _optimisticNote.tryEmit(note)
    }

    // Extended network caching
    internal var lastExtendedNetworkLoadTime = 0L
    /** True when the last extended-network tally ended on a relay timeout. */
    internal var extendedNetworkWasPartial = false

    // Guards loadMore() against re-entry from scroll-triggered re-fires
    internal val isLoadingMore = AtomicBoolean(false)

    /** True while an older page is being fetched; the feed's spinner and retry key. */
    internal val _loadingOlder = MutableStateFlow(false)
    val loadingOlder: StateFlow<Boolean> = _loadingOlder.asStateFlow()

    // Search debounce
    private var searchDebounceJob: Job? = null

    // Filter recomputation coalescing
    internal var recomputeJob: Job? = null

    // ══════════════════════════════════════════════════════════════════
    // Lifecycle
    // ══════════════════════════════════════════════════════════════════

    /**
     * Cold-launch entry point.
     * Restores disk snapshot if available, then tops up from relays.
     */
    fun startInitialLoad() {
        if (BuildConfig.DEBUG) Log.d(TAG, "startInitialLoad: mode=${_feedMode.value}")

        // Pre-load WOT pubkeys so DISCOVERY and GLOBAL media modes work immediately
        loadWotPubkeys()

        if (_feedMode.value == FeedMode.POPULAR) {
            loadPopularFeed()
            return
        }

        scope.launch {
            val restored = restoreFromDiskIfAvailable()
            if (BuildConfig.DEBUG) Log.d(TAG, "startInitialLoad: snapshot restored=$restored, notes=${_notes.value.size}, followedPubkeys=${_followedPubkeys.value.size}")
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

            // Global is filtered against the trust graph; pick up one the relay
            // has written since the last read.
            if (isGlobalLikeMode()) loadWotPubkeys()
            // Global's thread replies were fetched under the old list and trust
            // setting (the shield's switch lands here); Threaded View fetches
            // them again for the reloaded posts.
            if (_feedMode.value == FeedMode.GLOBAL) resetFeedThreadReplies()

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
        val previousSubId = primaryFeedSubId()
        _feedMode.value = mode

        // Pending notes are raw, unfiltered for the previous mode — drop them so
        // the "New Posts" count doesn't carry over stale entries. Live subs for
        // the new mode will repopulate.
        _pendingNotes.value = emptyList()
        resetFeedThreadReplies()

        when (mode) {
            FeedMode.POPULAR -> loadPopularFeed()
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
    fun setLongFormFeedMode(feed: FeedMode, mode: MediaFeedMode) {
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

    fun setMediaFeedMode(mode: MediaFeedMode) {
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
     * Persists a snapshot for instant resume and disconnects feed WebSockets
     * to free network/memory while the relay keeps running via the foreground service.
     */
    fun pauseFeed() {
        if (BuildConfig.DEBUG) Log.d(TAG, "pauseFeed: persisting snapshot and disconnecting feed clients")
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
        if (BuildConfig.DEBUG) Log.d(TAG, "resumeFeed: notes=${_notes.value.size}, followedPubkeys=${_followedPubkeys.value.size}")

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

    // ══════════════════════════════════════════════════════════════════
    // Contact list management
    // ══════════════════════════════════════════════════════════════════

    /**
     * Follow / unfollow taps made before the follow list had loaded. Applied, in
     * order, once it has (parity with iOS #160): publishing a list before then
     * could replace the real one on every relay, and the tap used to be dropped
     * without a word.
     */
    internal data class PendingFollow(val pubkey: String, val follow: Boolean, val account: String)
    internal val pendingFollowActions = mutableListOf<PendingFollow>()

    /**
     * The user's real follow list is known for this account (see
     * ContactManager.loadConfirmsList). Until it is, follow / unfollow never
     * publish: a timed-out load leaves an empty or partial list in memory, and
     * publishing it would replace every follow on every relay (iOS #180).
     */
    private val _contactListConfirmed = MutableStateFlow(false)
    internal var contactListConfirmed: Boolean
        get() = _contactListConfirmed.value
        set(value) { _contactListConfirmed.value = value }

    /**
     * The real follow list has loaded for the active account: the same test
     * Follow uses before it publishes. Until then the follow list can read
     * empty for someone who follows hundreds. iOS: FeedService.followListIsKnown.
     */
    val followListIsKnown: StateFlow<Boolean> = combine(
        _hasAttemptedContactLoad, _isLoadingContacts, _contactListConfirmed,
    ) { attempted, loading, confirmed ->
        contactManager.mayPublishFollowList(attempted, loading, confirmed)
    }.stateIn(scope, SharingStarted.Eagerly, false)

    /**
     * Scan configured relays for the owner's historical kind-3 (contact list)
     * events, collecting every distinct version found. Used by Following Backup
     * recovery to restore an older following list. Port of iOS queryRelaysForKind3.
     */
    /** [ownerHex] is the account whose lists to find; Following Backup can pick one that isn't active. */
    suspend fun scanRelaysForKind3(ownerHex: String = nostrService.activeHexPubkey): List<Kind3Event> {
        val config = configStore.config.value
        val relayUrls = buildList {
            config.nostrURL?.let { add(it) }
            config.inboxRelays?.let { addAll(it) }
            config.activeBlastrRelays.let { addAll(it) }
        }.distinct().take(6)
        if (relayUrls.isEmpty() || ownerHex.isEmpty()) return emptyList()

        val whitelistedNpubs = config.whitelistedNpubs ?: emptyList()
        val collected = ConcurrentHashMap<String, Kind3Event>() // keyed by event id

        coroutineScope {
            relayUrls.map { relayUrl ->
                launch(Dispatchers.IO) {
                    val client = WebSocketClient(
                        url = relayUrl,
                        scope = scope,
                        trustLocalhost = relayUrl.contains("localhost") || relayUrl.contains("127.0.0.1"),
                    )
                    val subId = "k3scan-${UUID.randomUUID().toString().take(8)}"
                    // Parsed off Main (kind-3s are large); `collected` is concurrent.
                    val collector = scope.launch(processingDispatcher) {
                        client.messages.collect { msg ->
                            try {
                                val parsed = json.parseToJsonElement(msg).jsonArray
                                if (parsed.size >= 3 && parsed[0].jsonPrimitive.contentOrNull == "EVENT") {
                                    val eventObj = parsed[2].jsonObject
                                    // Restore republishes this list as yours, so like
                                    // fetchContactList only the owner's signed kind 3 counts.
                                    if (!isOwnSignedContactList(eventObj, ownerHex, HavenBridge::verifyEvent)) return@collect
                                    val id = eventObj["id"]?.jsonPrimitive?.contentOrNull ?: return@collect
                                    if (collected.containsKey(id)) return@collect
                                    val createdAt = eventObj["created_at"]?.jsonPrimitive?.longOrNull ?: 0L
                                    val tags = eventObj["tags"]?.jsonArray?.map { tagArr ->
                                        tagArr.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" }
                                    } ?: emptyList()
                                    val content = eventObj["content"]?.jsonPrimitive?.contentOrNull ?: ""
                                    val pTags = tags.filter { it.firstOrNull() == "p" }
                                    val pubkeys = contactManager.parseContactList(tags, ownerHex, whitelistedNpubs).pubkeys
                                    if (pubkeys.isNotEmpty()) {
                                        collected[id] = Kind3Event(id, createdAt, pubkeys, pTags, content)
                                    }
                                }
                            } catch (_: Exception) {}
                        }
                    }
                    // Cancelled mid-scan (Following Backup switching account),
                    // the socket and its collector still close.
                    try {
                        client.connect()
                        client.send("[\"REQ\",\"$subId\",{\"kinds\":[3],\"authors\":[\"$ownerHex\"]}]")
                        delay(CONTACT_LOAD_TIMEOUT_MS)
                    } finally {
                        collector.cancel()
                        client.disconnect()
                    }
                }
            }.joinAll()
        }
        return collected.values.sortedByDescending { it.createdAt }
    }

    // ══════════════════════════════════════════════════════════════════
    // Extended network (discovery mode)
    // ══════════════════════════════════════════════════════════════════

    /**
     * How many people the follows bring in: the people they follow, freshly
     * tallied (an older tally predates the follows just made).
     */
    suspend fun countExtendedNetwork(): Int {
        loadExtendedNetwork()
        return _extendedNetworkPubkeys.value.size
    }

    /** Set by the feed list while a drag or fling is in progress. */
    fun setFeedScrolling(active: Boolean) {
        feedScrolling.value = active
    }

    /** The active account's blocked people, as hex pubkeys. */
    fun blockedHexForActiveAccount(): Set<String> =
        configStore.config.value.blockedForActiveAccount()
            .mapNotNull { nostrService.npubToHex(it) }.toSet()

    /**
     * How many staged new posts the current feed would actually show. The raw
     * pending list is unfiltered, and in Global with the Web of Trust on most
     * of it is filtered out: counting it raw put "50 new posts" on a pill that
     * revealed nothing.
     */
    fun visiblePendingCount(pending: List<FeedNote>): Int {
        if (pending.isEmpty()) return 0
        val config = configStore.config.value
        val blockedPubkeys = config.blockedForActiveAccount()
            .mapNotNull { nostrService.npubToHex(it) }.toSet()
        return if (_feedMode.value == FeedMode.MEDIA) {
            feedFilterEngine.filterMediaNotes(
                notes = pending,
                blocked = blockedPubkeys,
                wotPubkeys = _wotPubkeys.value,
                isGlobalMedia = _mediaFeedMode.value == MediaFeedMode.GLOBAL,
                globalRequiresTrust = !config.globalShowsEveryone,
                authorOf = ::authorOf,
            ).size
        } else {
            filterForCurrentFeed(pending, config, blockedPubkeys).size
        }
    }

    /**
     * Detected language per note id ("" = could not be told). Only filled
     * while the Global feed is narrowed to some languages. Concurrent because
     * a cancelled recompute can still be finishing on another thread.
     */
    internal val noteLanguageCache = ConcurrentHashMap<String, String>()

    /**
     * Web of Trust / Everyone for Global and Media's Global. Re-filters
     * straight away, then reloads, so the switch visibly lands both ways:
     * back to the Web of Trust the untrusted posts go at once instead of
     * lingering in the list and the new-posts count (iOS #133).
     */
    fun setGlobalShowsEveryone(on: Boolean) {
        if (configStore.config.value.globalShowsEveryone == on) return
        configStore.update { it.copy(globalShowsEveryone = on) }
        recomputeFilteredNotes()
        refresh()
    }

    /** Narrow Global to these ISO 639-1 codes; empty shows every language. */
    fun setGlobalFeedLanguages(codes: List<String>) {
        configStore.update { it.copy(globalFeedLanguages = codes.distinct()) }
        recomputeFilteredNotes()
    }

    fun setShowReposts(show: Boolean) {
        configStore.update { it.copy(showReposts = show) }
        recomputeFilteredNotes()
    }

    fun setShowReplies(show: Boolean) {
        configStore.update { it.copy(showReplies = show) }
        recomputeFilteredNotes()
    }

    /** Polls' Open / Closed / All only re-filters: every poll is already loaded. */
    fun setPollStatusFilter(filter: com.nostrvault.data.model.PollStatusFilter) {
        if (_pollStatusFilter.value == filter) return
        _pollStatusFilter.value = filter
        recomputeFilteredNotes()
    }

    fun setPopularFilter(filter: PopularFilter) {
        _popularFilter.value = filter
        recomputeFilteredNotes()
    }

    /**
     * Reloads the trust graph whenever the relay rewrites wot_cache.json. The
     * relay builds the graph in the background after it boots — usually after
     * the feed has already read the file (or found none) — so without this a
     * first launch kept Global and Discovery empty until the user happened to
     * refresh. Held in a field: a FileObserver stops when it is collected.
     */
    internal var wotCacheObserver: FileObserver? = null

    @Suppress("DEPRECATION") // FileObserver(File) needs API 29; minSdk is 26.

    fun loadWotPubkeys() {
        scope.launch(Dispatchers.IO) {
            try {
                val config = configStore.config.value
                config.relayDataDir?.let { watchWotCache(it) }
                val wotCachePath = config.relayDataDir?.let { "$it/$WOT_CACHE_FILE" }
                if (wotCachePath != null) {
                    val file = File(wotCachePath)
                    if (file.exists()) {
                        val text = file.readText()
                        val loaded = FeedFilterEngine.parseWotCache(text, nostrService.activeHexPubkey)
                        val vouches = TrustMap.vouches(text)
                        if (loaded == null) {
                            Log.w(TAG, "WoT cache unreadable: $wotCachePath")
                            return@launch
                        }
                        if (BuildConfig.DEBUG) Log.d(TAG, "WoT loaded: ${loaded.size} pubkeys")
                        withContext(Dispatchers.Main.immediate) {
                            _wotCacheRead.value = true
                            // Before the graph: its collectors read the vouches straight away.
                            _wotVouches.value = vouches
                            if (loaded != _wotPubkeys.value) {
                                _wotPubkeys.value = loaded
                                // Global is filtered against this set; notes
                                // already on screen have to be re-judged.
                                recomputeFilteredNotes()
                            }
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

    /** [undo], when given, is offered on the "Followed" pill. */
    fun followUser(pubkey: String, undo: (() -> Unit)? = null): Result<Unit> {
        if (!_hasAttemptedContactLoad.value || _isLoadingContacts.value) {
            queueFollowAction(pubkey, follow = true)
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
            listConfirmed = contactListConfirmed,
        )
        return result.fold(
            onSuccess = { followResult ->
                val previous = _followedPubkeys.value
                _followedPubkeys.value = followResult.pubkeys
                publishContactList(followResult.pubkeys, rollback = previous) {
                    notificationManager.showFollow(displayName, FollowKind.FAILED(followFailedMessage(follow = true)))
                }
                // Re-filter so already-loaded notes from the newly-followed author
                // surface immediately in the Following feed.
                recomputeFilteredNotes()
                // Re-issue the live primary REQ so the new follow's FUTURE notes
                // stream in without waiting for a full refresh.
                resubscribePrimaryToConnected()
                notificationManager.showFollow(displayName, FollowKind.FOLLOWED, undo, pubkey = pubkey)
                Result.success(Unit)
            },
            onFailure = {
                if (it is ContactManager.FollowActionError.ListUnavailable) {
                    // Kept queued and retried; never published against an unknown list.
                    queueFollowAction(pubkey, follow = true)
                    return Result.failure(it)
                }
                // A tap made while the list read empty: it was already done (iOS
                // resolves .alreadyFollowing as followed).
                val kind = if (it is ContactManager.FollowActionError.AlreadyFollowing) FollowKind.FOLLOWED
                else FollowKind.FAILED(it.message ?: "Failed")
                notificationManager.showFollow(displayName, kind, pubkey = pubkey)
                Result.failure(it)
            },
        )
    }

    /** [undo], when given, is offered on the "Unfollowed" pill. */
    fun unfollowUser(pubkey: String, undo: (() -> Unit)? = null): Result<Unit> {
        if (!_hasAttemptedContactLoad.value || _isLoadingContacts.value) {
            queueFollowAction(pubkey, follow = false)
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
            listConfirmed = contactListConfirmed,
        )
        return result.fold(
            onSuccess = { followResult ->
                if (contactManager.shouldBlockPublish(followResult.pubkeys.size, _followedPubkeys.value.size)) {
                    notificationManager.showFollow(displayName, FollowKind.FAILED(followFailedMessage(follow = false)), pubkey = pubkey)
                    return Result.failure(FollowActionError.SafetyCheckFailed)
                }
                val previous = _followedPubkeys.value
                _followedPubkeys.value = followResult.pubkeys
                publishContactList(followResult.pubkeys, rollback = previous) {
                    notificationManager.showFollow(displayName, FollowKind.FAILED(followFailedMessage(follow = false)))
                }
                // Re-filter so the unfollowed author's notes disappear from the
                // Following feed immediately (the filter excludes non-follows).
                recomputeFilteredNotes()
                // Re-issue the live primary REQ so the relay stops streaming the
                // unfollowed author's future notes.
                resubscribePrimaryToConnected()
                notificationManager.showFollow(displayName, FollowKind.UNFOLLOWED, undo, pubkey = pubkey)
                Result.success(Unit)
            },
            onFailure = {
                if (it is ContactManager.FollowActionError.ListUnavailable) {
                    // Kept queued and retried; never published against an unknown list.
                    queueFollowAction(pubkey, follow = false)
                    return Result.failure(it)
                }
                notificationManager.showFollow(displayName, FollowKind.FAILED(it.message ?: "Failed"), pubkey = pubkey)
                Result.failure(it)
            },
        )
    }

    /** Check if a pubkey is in the followed list. */
    fun isFollowing(pubkey: String): Boolean =
        _followedPubkeys.value.contains(pubkey)

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

    /**
     * Block for the active account. This wrote the legacy flat `blockedNpubs`,
     * which the feed filter ignores once a per-account list exists, and then
     * published that stale list as the owner's mute list, dropping anyone
     * blocked from Settings and, on a second account, signing as the owner.
     */
    fun blockUser(hexPubkey: String) {
        val npub = nostrService.hexToNpub(hexPubkey) ?: return
        if (npub in configStore.config.value.blockedForActiveAccount()) return
        configStore.blockProfile(npub)
        publishActiveMuteList()
        _notes.value = _notes.value.filter { it.pubkey != hexPubkey }
        recomputeFilteredNotes()
    }

    fun unblockUser(hexPubkey: String) {
        val npub = nostrService.hexToNpub(hexPubkey) ?: return
        if (npub !in configStore.config.value.blockedForActiveAccount()) return
        configStore.unblockProfile(npub)
        publishActiveMuteList()
    }

    fun isBlocked(hexPubkey: String): Boolean {
        val npub = nostrService.hexToNpub(hexPubkey) ?: return false
        return npub in configStore.config.value.blockedForActiveAccount()
    }

    fun applyPendingNotes() {
        val pending = _pendingNotes.value
        if (pending.isEmpty()) return

        _notes.value = (pending + _notes.value)
            .distinctBy { it.id }
            .sortedByDescending { it.createdAt }
            .take(MAX_FEED_NOTES)
        _pendingNotes.value = emptyList()
        _newNoteCount.value = 0
        recomputeFilteredNotes()
    }

    // ── Scroll position tracking ─────────────────────────────────

    fun updateScrollPosition(index: Int, offset: Int) {
        _savedScrollIndex = index
        _savedScrollOffset = offset
    }

    fun clearRestoredScrollPosition() {
        _restoredScrollPosition.value = null
    }

    /**
     * Drives the scroll-condense animation of the bottom nav bar + compose FAB
     * (iOS parity with FeedService.feedScrollingDown). StateFlow dedups equal
     * values, so the feed screen can call this freely; only an actual flip
     * publishes, keeping the bar/FAB the sole recomposing consumers.
     */
    fun requestRelayDashboard() {
        _relayDashboardRequest.tryEmit(Unit)
    }

    fun setFeedScrollingDown(value: Boolean) {
        // When the user disables the tab bar animation, the bar (and compose FAB)
        // must stay fully expanded, so never publish a "scrolling down" flip.
        if (value && configStore.config.value.disableTabBarAnimation) return
        _feedScrollingDown.value = value
    }

    fun requestScrollToTop() {
        _scrollToTopRequest.tryEmit(Unit)
    }

    // Thread grouping resolves every missing ancestor through findNote, so a
    // scan of the whole feed per lookup kept the UI thread busy for seconds.
    // Rebuilt once per notes list; the first note matching by id or
    // effectiveEventId wins, as the scan did.
    @Volatile internal var noteIndex: Pair<List<FeedNote>, Map<String, FeedNote>>? = null

    /**
     * Builds the note index for the current list, so the next lookup on Main
     * does not. The feed calls it off Main when its list changes.
     */
    fun warmNoteIndex() {
        noteIndex()
    }

    fun findNote(id: String): FeedNote? {
        return noteIndex()[id]
            ?: _parentNotesCache.value[id]
            // A reply fetched for a threaded card, opened in place: replying
            // to it, quoting it or opening its thread resolves it here.
            ?: _feedThreadReplies.value[id]
            // Quoted addressable events are keyed by coordinate, so a lookup by
            // id has to scan them — without this, opening a quoted article
            // refetches an event already in memory.
            ?: _quotedAddressCache.value.values.firstOrNull { it.id == id }
    }

    /**
     * The note a quote of [id] should cite: the original when [id] names a
     * kind-6 repost or the original it carries. See [FeedNote.quoteTarget].
     */
    fun quoteTarget(id: String): FeedNote? {
        val note = findNote(id) ?: return null
        return FeedNote.quoteTarget(note) { ref ->
            _notes.value.firstOrNull { it.id == ref && it.kind != 6 }
                ?: _parentNotesCache.value[ref]?.takeIf { it.id == ref && it.kind != 6 }
        }
    }

    /**
     * Register a note in the supplementary cache so that [findNote] can locate
     * it even when the note isn't part of the main feed list. Called by
     * ProfileViewModel and NoteDetailViewModel so ComposeNoteScreen can resolve
     * reply/quote targets loaded outside the feed.
     */
    fun cacheNote(note: FeedNote) {
        if (hidesDeleted(note)) return
        var updated = _parentNotesCache.value + (note.id to note)
        // For kind-6 reposts, also cache under the original note's ID so
        // lookups by effectiveEventId succeed.
        if (note.effectiveEventId != note.id) {
            updated = updated + (note.effectiveEventId to note)
        }
        _parentNotesCache.value = updated
    }

    // ══════════════════════════════════════════════════════════════════
    // Note fetching (threading)
    // ══════════════════════════════════════════════════════════════════

    /**
     * Referenced notes (thread roots, parents, quotes) no relay returned after
     * both passes. Thread cards drop their "Loading the start of this
     * thread…" line for these instead of showing it forever.
     */
    internal val _unavailableNoteIds = MutableStateFlow<Set<String>>(emptySet())
    val unavailableNoteIds: StateFlow<Set<String>> = _unavailableNoteIds.asStateFlow()

    /**
     * When each id was given up on. Unavailable is not forever: past
     * [UNAVAILABLE_RETRY_MS] the next request asks again, so a launch on a bad
     * network doesn't hide those notes for the rest of the session.
     */
    internal val unavailableSince = ConcurrentHashMap<String, Long>()

    /** Ids queued for the next lookup, or being looked up right now. */
    private val noteFetchQueue = mutableSetOf<String>()
    internal val noteFetchInFlight = ConcurrentHashMap.newKeySet<String>()
    /** Guards [noteFetchQueue] and [noteFetchFlushJob] together. */
    private val noteFetchLock = Any()
    private var noteFetchFlushJob: Job? = null

    /** Authors whose relay list was already requested, so each is asked once. */
    internal val relayListRequested = ConcurrentHashMap.newKeySet<String>()

    /**
     * Thread cards ask for their root one at a time as they compose. Queue
     * them and look up the batch together, so a screenful of cards shares
     * one REQ per relay instead of a socket fan-out each.
     */
    fun fetchMissingNote(id: String) = fetchMissingNotesBatch(listOf(id))

    fun fetchMissingNotesBatch(ids: List<String>) {
        // A post that arrived through the feed itself can be the parent (or
        // repost original, or quote) a row is waiting on. Rows read parents
        // from the cache only, so they kept their skeleton until a relay
        // answered for a note the phone already had (iOS #302). Checked
        // before the in-flight filter: the feed often delivers it mid-lookup.
        val inFeed = adoptFeedNotes(ids)
        val deleted = markDeletedUnavailable(ids)
        val now = System.currentTimeMillis()
        val wanted = ids.filter { id ->
            if (id in inFeed || id in deleted) return@filter false
            if (_parentNotesCache.value.containsKey(id) || id in noteFetchInFlight) return@filter false
            val since = unavailableSince[id] ?: return@filter true
            now - since >= UNAVAILABLE_RETRY_MS
        }
        if (wanted.isEmpty()) return
        synchronized(noteFetchLock) {
            noteFetchQueue.addAll(wanted)
            if (noteFetchFlushJob != null) return
            noteFetchFlushJob = scope.launch(Dispatchers.IO) {
                // Drain until nothing new arrived during the wait. The lookups
                // run outside this job: as children they kept it active for the
                // whole fetch window, and ids queued meanwhile were never sent.
                while (true) {
                    delay(NOTE_FETCH_BATCH_DELAY_MS)
                    val batch = synchronized(noteFetchLock) {
                        val b = noteFetchQueue.toList()
                        noteFetchQueue.clear()
                        // Cleared under the same lock an enqueue checks, so an
                        // id added after this either sees the job and is drained,
                        // or sees null and starts the next one.
                        if (b.isEmpty()) noteFetchFlushJob = null
                        b
                    }
                    if (batch.isEmpty()) break
                    noteFetchInFlight.addAll(batch)
                    for (chunk in batch.chunked(50)) {
                        scope.launch(Dispatchers.IO) { lookUpNotes(chunk) }
                    }
                }
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Quoted note resolution (embedded nostr:note1/nevent1 previews)
    // ══════════════════════════════════════════════════════════════════

    /**
     * Resolve a quoted-event lookup key to a cached note, if already fetched.
     *
     * [identifier] is what `FeedNote.quotedEventIds` holds: a hex event id, or
     * an `naddr:` coordinate. It used to be decoded from bech32 here as well,
     * which meant that once the parser started handing out hex this rejected
     * every key it was given and no quoted note ever resolved. [QuoteRef.key]
     * is now the only thing that reads a key, on both sides.
     */
    fun quotedNoteFor(identifier: String): FeedNote? =
        when (val key = QuoteRef.key(identifier)) {
            is QuoteRef.Key.Event -> _parentNotesCache.value[key.hexId] ?: findNote(key.hexId)
            is QuoteRef.Key.Address -> _quotedAddressCache.value[identifier]
            null -> null
        }

    /** Batch-fetch quoted events that aren't cached yet. */
    fun fetchMissingQuotedNotes(identifiers: List<String>) {
        val keys = identifiers.distinct().mapNotNull { id -> QuoteRef.key(id)?.let { id to it } }

        val hexIds = keys.mapNotNull { (_, key) -> (key as? QuoteRef.Key.Event)?.hexId }
        if (hexIds.isNotEmpty()) fetchMissingNotesBatch(hexIds)

        val coordinates = keys.mapNotNull { (raw, key) ->
            (key as? QuoteRef.Key.Address)?.let { raw to it.coordinate }
        }.filter { (raw, _) -> !_quotedAddressCache.value.containsKey(raw) }
        if (coordinates.isNotEmpty()) fetchQuotedAddressesBatch(coordinates)
    }

    /**
     * Fetch one addressable event (a `nostr:naddr1…` link) from the user's own
     * relays, the same way a quoted naddr is fetched, and wait up to
     * [timeoutMs] for it. Relays may answer with older revisions first, so it
     * waits [settleMs] after the first answer and returns the newest.
     */
    suspend fun resolveAddress(coordinate: QuoteRef.Coordinate, timeoutMs: Long = 8_000, settleMs: Long = 600): FeedNote? {
        val key = QuoteRef.format(coordinate)
        fetchMissingQuotedNotes(listOf(key))
        withTimeoutOrNull(timeoutMs) { _quotedAddressCache.first { it.containsKey(key) } } ?: return null
        delay(settleMs)
        return _quotedAddressCache.value[key]
    }

    /** Fetch profiles for the authors of resolved quoted notes that lack one. */
    fun fetchMissingQuotedProfiles(identifiers: List<String>) {
        val missingAuthors = identifiers
            .mapNotNull { quotedNoteFor(it)?.pubkey }
            .filter { nostrService.profiles.value[it] == null }
            .distinct()
        if (missingAuthors.isNotEmpty()) nostrService.fetchMissingProfiles(missingAuthors)
    }

    /**
     * Fetches replies to these Popular or Global posts (once per post per
     * list) from the local relay and the feed relays. Only signature-checked
     * events are kept, and only those [FeedThreadReplies.admits]: real
     * replies into one of these threads, from nobody blocked, and on Global
     * from inside the trust rule. iOS: `FeedService.loadFeedThreadReplies`.
     *
     * Global's list grows with every stream batch, so the ids are queued and
     * one worker asks for them, after a short settle, in chunks — rather than
     * a REQ per batch of three new posts.
     */
    fun loadFeedThreadReplies(postIds: List<String>) {
        if (!FeedThreadReplies.fetchesReplies(_feedMode.value)) return
        synchronized(threadRepliesLock) {
            for (id in postIds) if (threadRepliesRequested.add(id)) threadRepliesPending.add(id)
            if (threadRepliesPending.isEmpty() || threadRepliesJob != null) return
            val generation = threadRepliesGeneration
            threadRepliesJob = scope.launch(processingDispatcher) { drainThreadReplies(generation) }
        }
    }

    /** Who reacted, zapped and reposted one note. See FeedServiceEngagementDetails.kt. */
    fun fetchEngagementDetails(noteId: String, callback: (EngagementDetails) -> Unit) =
        loadEngagementDetails(noteId, callback)

    /** Thread Stats: the same for every note in a thread. See FeedServiceEngagementDetails.kt. */
    fun fetchThreadEngagement(noteIds: List<String>, callback: (Map<String, EngagementDetails>) -> Unit) =
        loadThreadEngagement(noteIds, callback)

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

    /**
     * The reaction button. A tap ([emoji] null) reacts with the default
     * reaction, or takes the account's reaction back when it has one. A
     * picked [emoji] (tapback bar or picker) is sent instead, replacing any
     * other reaction; picking the one already sent takes it back. iOS #322.
     */
    fun likeNote(noteId: String, emoji: String? = null, tags: List<List<String>>? = null) {
        val isLiked = noteId in _likedEventIds.value
        val current = _myReactions.value[noteId]?.content
        val change = if (emoji == null) {
            ReactionChoice.forTap(isLiked, configStore.config.value.defaultReactionEmoji)
        } else {
            ReactionChoice.forPick(isLiked, current, emoji)
        }
        when (change) {
            is ReactionChoice.Change.React -> react(noteId, change.content, tags)
            ReactionChoice.Change.Remove -> removeReaction(noteId)
        }
    }

    /** Repost a note (kind 6 for kind-1 notes, kind 16 + k-tag otherwise, per NIP-18). */
    fun repostNote(noteId: String) {
        val existing = _repostedEventIds.value
        if (noteId in existing) return
        _repostedEventIds.value = existing + noteId

        scope.launch(Dispatchers.IO) {
            // NIP-18: always repost the ORIGINAL event, not a repost wrapper. For kind
            // 6 notes, repostedEventId points to the original kind-1 event (the only
            // kind this app has ever wrapped in kind 6).
            val note = findNote(noteId)
            val originalId = note?.repostedEventId ?: noteId
            // A bare repost still carries the reposter's pubkey.
            val originalPubkey = note?.effectiveAuthor
            val originalKind = note?.effectiveKind ?: 1

            val rawEvent = rawEventCache[originalId] ?: ""
            val config = configStore.config.value
            // NIP-18: e tag MUST include a relay URL as its third entry.
            val relayHint = config.activeFeedRelays.firstOrNull()
                ?: config.activeBlastrRelays.firstOrNull()
                ?: (config.nostrURL ?: "")

            // NIP-18: kind 6 is reserved for reposting kind-1 notes. Anything else
            // (e.g. a kind-30023 long-form article) needs kind 16 with a "k" tag
            // naming the original kind, or most clients will reject/ignore it.
            val repostKind = if (originalKind == 1) 6 else 16
            val tags = buildList {
                add(listOf("e", originalId, relayHint))
                originalPubkey?.let { add(listOf("p", it)) }
                if (repostKind == 16) add(listOf("k", originalKind.toString()))
            }
            val event = runCatching { nostrService.signEventAsync(kind = repostKind, content = rawEvent, tags = tags) }
                .onFailure { Log.e(TAG, "repost not signed: ${it.message}") }.getOrNull()
            if (event != null) {
                nostrService.postEvent(event)
            } else {
                // Nothing was published — undo the optimistic repost.
                _repostedEventIds.value = _repostedEventIds.value - noteId
                val stats = _noteStats.value.toMutableMap()
                val st = stats[noteId] ?: NoteStats()
                stats[noteId] = st.copy(repostCount = maxOf(0, st.repostCount - 1))
                _noteStats.value = stats
            }
        }

        val stats = _noteStats.value.toMutableMap()
        val existing2 = stats[noteId] ?: NoteStats()
        stats[noteId] = existing2.copy(repostCount = existing2.repostCount + 1)
        _noteStats.value = stats
    }

}

// AccumulatorBatch replaced by BackgroundAccumulator.Snapshot in FeedServiceTypes.kt
