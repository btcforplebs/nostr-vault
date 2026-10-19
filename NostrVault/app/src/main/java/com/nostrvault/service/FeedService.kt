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
    internal val blobNoteIndexStore: BlobNoteIndexStore,
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
        internal const val NOTE_FETCH_BATCH_DELAY_MS = 300L
        internal const val UNAVAILABLE_RETRY_MS = 60_000L
        /** Quiet time after a batch of follows' relay lists before re-planning. */
        internal const val OUTBOX_RELAY_LIST_SETTLE_MS = 5_000L
        /** Failed connects in a row before a feed relay counts as down. */
        internal const val FEED_RELAY_DOWN_AFTER = 3

        /**
         * Asked on the second pass, for referenced notes neither your relays
         * nor the author's carry. Same list as iOS FeedService.fallbackNoteRelays,
         * picked by measurement on 2026-10-01; re-measure with
         * `.scratch/roots/probe5.py` in the Buzz nest before changing it.
         * offchain.pub refused connections on 2026-10-12 and was dropped.
         *
         * relay.nostr.net and relay.fountain.fm are the last stop. On
         * 2026-10-16, of 172 referenced notes still missing after primal and
         * the rest of this list, those two found 112, the best pair of the 20
         * relays tried. A quote in Logen's thread (Plural's, a2f86e95) was on
         * fountain.fm alone.
         */
        /**
         * zap.cooking's own feed relay: curated recipe posts, read-only, no
         * login needed. On 2026-10-17 it answered the Recipes filter with 200
         * recipes from 65 authors; primal had 51 from 9. Logen wants the
         * Recipes tab to use it (iOS RecipeFeedService.zapCookingRelay).
         */
        internal const val ZAP_COOKING_RELAY = "wss://feed.zap.cooking"

        /** [relays], plus [ZAP_COOKING_RELAY] when the feed is Recipes. */
        internal fun relaysForMode(mode: FeedMode, relays: List<String>): List<String> =
            if (mode == FeedMode.RECIPES) (relays + ZAP_COOKING_RELAY).distinct() else relays

        internal val FALLBACK_NOTE_RELAYS = listOf(
            "wss://nostr.wine",
            "wss://nostr.oxtr.dev",
            "wss://nostr.land",
            "wss://relay.nostrplebs.com",
            "wss://relay.snort.social",
            "wss://relay.primal.net",
            "wss://relay.damus.io",
            "wss://relay.nostr.net",
            "wss://relay.fountain.fm",
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

    fun relayTabTrustedPubkeys(): Set<String> = relayTabTrustedPubkeysImpl()

    fun globalTrustSet(): Set<String>? = globalTrustSetImpl()

    internal val _notes = MutableStateFlow<List<FeedNote>>(emptyList())
    val notes: StateFlow<List<FeedNote>> = _notes.asStateFlow()

    // Periodic disk-snapshot persistence (crash safety). Persisting only in
    // pauseFeed() loses the whole session when the process is killed without a
    // lifecycle callback; persist at most once a minute while the feed changes.
    internal var snapshotDirty = false

    /**
     * hash → note id for every blob this device has seen a note reference.
     *
     * Exposed here because the media gallery already holds this service, and
     * because the thing that fills the index is the note stream this service
     * owns. Reading it is what stops "Open Note" on a blob from depending on
     * how far the feed happened to be scrolled — see [BlobNoteIndexStore].
     */
    val blobNoteIndex: StateFlow<Map<String, String>> = blobNoteIndexStore.index

    init { startObservers() }

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

    private val followSet = SetOfList<String>()

    /** [followedPubkeys] as a Set, rebuilt only when the list changes. iOS `followedPubkeySet`. */
    internal fun followedPubkeySet(): Set<String> = followSet.of(_followedPubkeys.value)

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

    internal val _repostedEventIds = MutableStateFlow<Set<String>>(emptySet())
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

    /** The rank line over each Popular post; off until the Ranks button turns it on, as on iOS. */
    private val _showPopularEngagement = MutableStateFlow(false)
    val showPopularEngagement: StateFlow<Boolean> = _showPopularEngagement.asStateFlow()
    fun toggleShowPopularEngagement() { _showPopularEngagement.value = !_showPopularEngagement.value }

    internal val _popularNoteScores = MutableStateFlow<Map<String, Double>>(emptyMap())
    val popularNoteScores: StateFlow<Map<String, Double>> = _popularNoteScores.asStateFlow()
    internal val modeCaches = FeedModeCaches() // Each feed kept for a switch back: FeedServiceModeCache.kt

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
    internal val _wotVouches = MutableStateFlow<Map<String, Int>?>(null)
    val wotVouches: StateFlow<Map<String, Int>?> = _wotVouches.asStateFlow()

    /**
     * True once the relay's graph file has been read for this account, even
     * if it named nobody. Separates "no graph built yet" from "built and
     * empty because you follow nobody". iOS: FeedService.wotCacheRead.
     */
    internal val _wotCacheRead = MutableStateFlow(false)
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

    /** What [outboxPlan] was built from; null when there is no plan. */
    @Volatile internal var outboxPlanInputs: FeedOutboxPlan.Inputs? = null

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

    /** Set once a launch prewarm put the disk snapshot on screen. See [prewarmFromCache]. */
    @Volatile internal var cachedFeedRestored = false
    @Volatile internal var initialLoadStarted = false
    internal var prewarmJob: Job? = null

    fun startInitialLoad() { startInitialLoadImpl() }

    /** Shows the cached feed before the relay is ready. iOS `prewarmFromCache`. */
    fun prewarmFromCache() { prewarmFromCacheImpl() }

    /** Whether the relay coming up should start the feed's first load. */
    fun needsInitialLoad(): Boolean =
        shouldStartInitialLoad(_notes.value.isEmpty(), cachedFeedRestored, initialLoadStarted)

    fun refresh() { refreshImpl() }

    fun forceReload() { forceReloadImpl() }

    fun switchMode(mode: FeedMode) { switchModeImpl(mode) }

    fun setLongFormFeedMode(feed: FeedMode, mode: MediaFeedMode) { setLongFormFeedModeImpl(feed, mode) }

    fun setMediaFeedMode(mode: MediaFeedMode) { setMediaFeedModeImpl(mode) }

    fun pauseFeed() { pauseFeedImpl() }

    fun resumeFeed() { resumeFeedImpl() }

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

    suspend fun scanRelaysForKind3(ownerHex: String = nostrService.activeHexPubkey): List<Kind3Event> = scanRelaysForKind3Impl(ownerHex)

    // ══════════════════════════════════════════════════════════════════
    // Extended network (discovery mode)
    // ══════════════════════════════════════════════════════════════════

    suspend fun countExtendedNetwork(): Int = countExtendedNetworkImpl()

    /** Set by the feed list while a drag or fling is in progress. */
    fun setFeedScrolling(active: Boolean) {
        feedScrolling.value = active
    }

    /** The active account's blocked people, as hex pubkeys. */
    fun blockedHexForActiveAccount(): Set<String> =
        configStore.config.value.blockedForActiveAccount()
            .mapNotNull { nostrService.npubToHex(it) }.toSet()

    fun visiblePendingCount(pending: List<FeedNote>): Int = visiblePendingCountImpl(pending)

    /**
     * Detected language per note id ("" = could not be told). Only filled
     * while the Global feed is narrowed to some languages. Concurrent because
     * a cancelled recompute can still be finishing on another thread.
     */
    internal val noteLanguageCache = ConcurrentHashMap<String, String>()

    fun setGlobalShowsEveryone(on: Boolean) { setGlobalShowsEveryoneImpl(on) }

    fun setGlobalFeedLanguages(codes: List<String>) { setGlobalFeedLanguagesImpl(codes) }

    fun setShowReposts(show: Boolean) { setShowRepostsImpl(show) }

    fun setShowReplies(show: Boolean) { setShowRepliesImpl(show) }

    fun setPollStatusFilter(filter: com.nostrvault.data.model.PollStatusFilter) { setPollStatusFilterImpl(filter) }

    /**
     * Reloads the trust graph whenever the relay rewrites wot_cache.json. The
     * relay builds the graph in the background after it boots — usually after
     * the feed has already read the file (or found none) — so without this a
     * first launch kept Global and Discovery empty until the user happened to
     * refresh. Held in a field: a FileObserver stops when it is collected.
     */
    internal var wotCacheObserver: FileObserver? = null

    fun loadWotPubkeys() { loadWotPubkeysImpl() }

    // ══════════════════════════════════════════════════════════════════
    // Following / unfollowing
    // ══════════════════════════════════════════════════════════════════

    fun followUser(pubkey: String, undo: (() -> Unit)? = null): Result<Unit> = followUserImpl(pubkey, undo)

    fun unfollowUser(pubkey: String, undo: (() -> Unit)? = null): Result<Unit> = unfollowUserImpl(pubkey, undo)

    /** Check if a pubkey is in the followed list. */
    fun isFollowing(pubkey: String): Boolean =
        pubkey in followedPubkeySet()

    /** Alias for followUser(), used by ProfileViewModel. */
    fun followPubkey(pubkey: String) { followUser(pubkey) }

    /** Alias for unfollowUser(), used by ProfileViewModel. */
    fun unfollowPubkey(pubkey: String) { unfollowUser(pubkey) }

    fun restoreContactList(pTags: List<List<String>>, content: String) { restoreContactListImpl(pTags, content) }

    // ══════════════════════════════════════════════════════════════════
    // User moderation
    // ══════════════════════════════════════════════════════════════════

    fun blockUser(hexPubkey: String) { blockUserImpl(hexPubkey) }

    fun unblockUser(hexPubkey: String) { unblockUserImpl(hexPubkey) }

    fun isBlocked(hexPubkey: String): Boolean {
        val npub = nostrService.hexToNpub(hexPubkey) ?: return false
        return npub in configStore.config.value.blockedForActiveAccount()
    }

    fun applyPendingNotes() { applyPendingNotesImpl() }

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

    fun findNote(id: String): FeedNote? = findNoteImpl(id)

    fun quoteTarget(id: String): FeedNote? = quoteTargetImpl(id)

    fun cacheNote(note: FeedNote) { cacheNoteImpl(note) }

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
    internal val noteFetchQueue = mutableSetOf<String>()
    internal val noteFetchInFlight = ConcurrentHashMap.newKeySet<String>()
    /** Guards [noteFetchQueue] and [noteFetchFlushJob] together. */
    internal val noteFetchLock = Any()
    internal var noteFetchFlushJob: Job? = null

    /** Authors whose relay list was already requested, so each is asked once. */
    internal val relayListRequested = ConcurrentHashMap.newKeySet<String>()

    /**
     * Thread cards ask for their root one at a time as they compose. Queue
     * them and look up the batch together, so a screenful of cards shares
     * one REQ per relay instead of a socket fan-out each.
     */
    fun fetchMissingNote(id: String) = fetchMissingNotesBatch(listOf(id))

    fun fetchMissingNotesBatch(ids: List<String>) { fetchMissingNotesBatchImpl(ids) }

    // ══════════════════════════════════════════════════════════════════
    // Quoted note resolution (embedded nostr:note1/nevent1 previews)
    // ══════════════════════════════════════════════════════════════════

    fun quotedNoteFor(identifier: String): FeedNote? = quotedNoteForImpl(identifier)

    fun fetchMissingQuotedNotes(identifiers: List<String>) { fetchMissingQuotedNotesImpl(identifiers) }

    suspend fun resolveAddress(coordinate: QuoteRef.Coordinate, timeoutMs: Long = 8_000, settleMs: Long = 600): FeedNote? = resolveAddressImpl(coordinate, timeoutMs, settleMs)

    fun fetchMissingQuotedProfiles(identifiers: List<String>) { fetchMissingQuotedProfilesImpl(identifiers) }

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

    fun likeNote(noteId: String, emoji: String? = null, tags: List<List<String>>? = null) { likeNoteImpl(noteId, emoji, tags) }

    fun repostNote(noteId: String) { repostNoteImpl(noteId) }

}

// AccumulatorBatch replaced by BackgroundAccumulator.Snapshot in FeedServiceTypes.kt
