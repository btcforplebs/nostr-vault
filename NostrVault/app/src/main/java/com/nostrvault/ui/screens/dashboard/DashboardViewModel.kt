package com.nostrvault.ui.screens.dashboard

import android.content.Intent
import android.util.Log
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.*
import androidx.compose.runtime.*
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import androidx.compose.foundation.layout.offset
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.*
import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.service.NostrEvent
import com.nostrvault.service.NWCService
import com.nostrvault.service.NostrService
import com.nostrvault.service.StatsService
import com.nostrvault.service.ZapHistoryService
import com.nostrvault.service.ZapValidationService
import com.nostrvault.ui.navigation.NotificationTarget
import com.nostrvault.ui.navigation.RelayFocusRequest
import com.nostrvault.ui.theme.*
import com.nostrvault.util.RelayGiven
import com.nostrvault.util.WalletTransaction
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject

/** What the Relay tab counts as a post: notes, reposts, articles, NIP-22
 *  comments, highlights and NIP-88 polls. Comments and highlights that tag you
 *  were never requested, so they never showed up there. iOS:
 *  NostrService.relayTabNoteKinds. */
internal val RELAY_TAB_NOTE_KINDS = setOf(1, 6, 30023, NIP10Thread.COMMENT_KIND, 9802, NIP88Poll.KIND)

/**
 * True when the Notes list holds back loaded notes behind its display cap, so
 * load-more only needs to raise the cap; false means everything loaded is
 * listed and older notes have to come from the relay.
 */

internal fun relayNotesHiddenBelowCap(filteredCount: Int, cap: Int): Boolean = filteredCount > cap

/**
 * Relay tab screen matching iOS VaultView:
 * - Notes / Likes / Zaps mode switcher in the leading toolbar pill
 * - Context-sensitive filters in the trailing toolbar pill
 * - Dashboard FAB for relay stats bottom sheet
 */

@HiltViewModel
class DashboardViewModel @Inject constructor(
    val statsService: StatsService,
    val configStore: ConfigStore,
    val nostrService: NostrService,
    internal val followersSeenStore: com.nostrvault.data.local.FollowersSeenStore,
    internal val blossomService: com.nostrvault.service.BlossomService,
    internal val feedService: com.nostrvault.service.FeedService,
    internal val nwcService: NWCService,
    internal val zapHistoryService: ZapHistoryService,
    /** "Last ran" times for the Vault Dashboard (iOS VaultHistory). */
    internal val vaultHistory: com.nostrvault.data.local.VaultHistoryStore,
    /** Stops the relay around a notes backup, like Settings › Backup. */
    internal val relayImportService: com.nostrvault.service.RelayImportService,
    /** The list on show, kept across Android killing the app; see [restoreSavedMode]. */
    internal val savedState: androidx.lifecycle.SavedStateHandle,
) : ViewModel() {

    /** The shared Blossom mirror run behind "Import Blossom" (iOS MirrorService). */
    val blossomMirrorRun = blossomService.mirrorRun

    companion object {
        internal const val TAG = "DashboardVM"
        private const val MAX_LOCAL_NOTES = 500
        private const val LOAD_TIMEOUT_MS = 15_000L
        internal const val LOAD_MORE_TIMEOUT_MS = 8_000L
        // High bound so the relay tab scrolls back through (effectively) full history.
        internal const val MAX_ALL_EVENTS = 10_000
        /** iOS establishNotificationBaseline's 3 s after the relay is up. */
        internal const val DOT_BASELINE_DELAY_MS = 3_000L
        internal const val ALL_EVENTS_TRIM_SLACK = 200
        internal const val MAX_SEEN_IDS = 10_000
        internal const val MAX_ZAP_RECEIPT_CACHE = 500
        /** Zaps > Given reads the wallet's 200 most recent payments. */
        internal const val WALLET_GIVEN_PAGES = 4
        internal const val WALLET_GIVEN_PAGE_SIZE = 50
        private const val SNAPSHOT_MAX_EVENTS = 500
        internal const val SNAPSHOT_MAX_AGE_MS = 24 * 60 * 60 * 1000L // 24 hours
        internal const val SNAPSHOT_FILE = "vault_snapshot.json"
        private const val FOLLOWERS_POLL_MS = 60_000L
        internal const val SAVED_VIEW_MODE = "vault.viewMode"
        internal const val SAVED_NOTE_SCOPE = "vault.noteScope"
        internal const val SAVED_RECIPES = "vault.recipesOnly"
        /** One Articles / Highlights "Load older" page, per query. */
        internal const val OLDER_PAGE_SIZE = 50
    }

    internal val json = Json { ignoreUnknownKeys = true }

    // ── Stats state ──────────────────────────────────────────────

    private val _totalEvents = MutableStateFlow(0)
    val totalEvents = _totalEvents.asStateFlow()

    private val _storageUsed = MutableStateFlow("")
    val storageUsed = _storageUsed.asStateFlow()

    private val _noteCount = MutableStateFlow(0)
    val noteCount = _noteCount.asStateFlow()

    private val _dmCount = MutableStateFlow(0)
    val dmCount = _dmCount.asStateFlow()

    private val _mediaCount = MutableStateFlow(0)
    val mediaCount = _mediaCount.asStateFlow()

    private val _mediaSize = MutableStateFlow("")
    val mediaSize = _mediaSize.asStateFlow()

    private val _statsLoading = MutableStateFlow(true)
    val statsLoading = _statsLoading.asStateFlow()

    // ── Import/Export state ──────────────────────────────────────

    // The one import path: RelayImportService runs it (Settings and the setup tour
    // use it too), so every entry point gets the foreground service, the relay
    // list files and the export guard. iOS: relayManager.importNotes.
    val isImporting = relayImportService.isImporting
    val importProgress = relayImportService.importProgress
    val importStatusMessage = relayImportService.importStatusMessage
    val importCompleted = relayImportService.importCompleted

    internal val _isExportingJsonl = MutableStateFlow(false)
    val isExportingJsonl = _isExportingJsonl.asStateFlow()

    internal val _isExportingMedia = MutableStateFlow(false)
    val isExportingMedia = _isExportingMedia.asStateFlow()

    private val _exportUri = MutableStateFlow<android.net.Uri?>(null)
    val exportUri = _exportUri.asStateFlow()

    /** The last export's outcome in words, for the Vault Dashboard (iOS VaultExporter.statusMessage). */
    internal val _exportStatus = MutableStateFlow("")
    val exportStatus = _exportStatus.asStateFlow()

    internal val _exportStatusIsError = MutableStateFlow(false)
    val exportStatusIsError = _exportStatusIsError.asStateFlow()
    internal var exportStatusClear: Job? = null

    // ── EOSE tracking per relay ──────────────────────────────────
    internal val relayEoseReceived = ConcurrentHashMap<String, Boolean>()
    internal val activeRelayUrls = mutableSetOf<String>()

    // ── View mode & filters ──────────────────────────────────────

    internal val _viewMode = MutableStateFlow(VaultViewMode.NOTES)
    val viewMode: StateFlow<VaultViewMode> = _viewMode.asStateFlow()

    internal val _contentFilter = MutableStateFlow(VaultContentFilter.ALL)
    val contentFilter: StateFlow<VaultContentFilter> = _contentFilter.asStateFlow()

    internal val _likesFilter = MutableStateFlow(VaultLikesFilter.ON_MY_NOTES)
    val likesFilter: StateFlow<VaultLikesFilter> = _likesFilter.asStateFlow()

    internal val _zapsFilter = MutableStateFlow(VaultZapsFilter.ON_MY_NOTES)
    val zapsFilter: StateFlow<VaultZapsFilter> = _zapsFilter.asStateFlow()

    internal val _followersFilter = MutableStateFlow(VaultFollowersFilter.NEW)
    val followersFilter: StateFlow<VaultFollowersFilter> = _followersFilter.asStateFlow()

    /** Notes, Articles or Highlights. Only the Vault tab's mode menu changes it. */
    internal val _noteScope = MutableStateFlow(VaultNoteScope.NOTES)
    val noteScope: StateFlow<VaultNoteScope> = _noteScope.asStateFlow()

    /** Articles only: just the recipes. */
    internal val _recipesOnly = MutableStateFlow(false)
    val recipesOnly: StateFlow<Boolean> = _recipesOnly.asStateFlow()

    // ── Articles / Highlights "Load older" ───────────────────────

    internal val _isLoadingOlder = MutableStateFlow(false)
    val isLoadingOlder: StateFlow<Boolean> = _isLoadingOlder.asStateFlow()

    /** Scopes whose last older page came back empty: nothing older to load. */
    internal val _noOlderPages = MutableStateFlow<Set<VaultNoteScope>>(emptySet())
    val noOlderPages: StateFlow<Set<VaultNoteScope>> = _noOlderPages.asStateFlow()

    /** Per scope: the outbox (your posts) and inbox (tagging you) cursors. */
    internal val olderCursors = ConcurrentHashMap<VaultNoteScope, Pair<VaultPageCursor, VaultPageCursor>>()
    /** Bumped on account switch, so a page still loading for the previous account is dropped. */
    @Volatile internal var olderGeneration = 0

    // ── Followers (relay follower ledger, iOS #136) ──────────────

    /** Null while the relay is stopped or the ledger hasn't opened yet. */
    internal val _followerSnapshot = MutableStateFlow<FollowerSnapshot?>(null)
    val followerSnapshot: StateFlow<FollowerSnapshot?> = _followerSnapshot.asStateFlow()

    /** Red dot on the Followers mode button: follows since the owner last looked. */
    internal val _hasNewFollowers = MutableStateFlow(false)
    val hasNewFollowers: StateFlow<Boolean> = _hasNewFollowers.asStateFlow()

    /** Notes, Likes and Zaps lists with something new since you last looked (iOS hasNewNotes/Likes/Zaps). */
    internal val _newActivity = MutableStateFlow<Set<VaultViewMode>>(emptySet())

    /**
     * When each dotted list was last looked at, as the newest created_at it
     * held then. Empty until the first load settles: before that everything
     * would read as new.
     */
    internal val dotSeenAt = ConcurrentHashMap<VaultViewMode, Long>()
    internal var dotBaselineJob: Job? = null
    /** The list in sight at the last check, so leaving it marks it seen too. */
    private var lastWatched: VaultViewMode? = null

    /** Modes with something new since you last looked, for the Vault pill's dot on either half. */
    val newModes: StateFlow<Set<VaultMode>> = kotlinx.coroutines.flow.combine(
        _newActivity, _hasNewFollowers, configStore.config.map { it.zapsOnlyMode }.distinctUntilChanged(),
    ) { lists, followers, zapsOnly -> VaultDots.shown(lists, followers, zapsOnly) }.stateIn(viewModelScope, kotlinx.coroutines.flow.SharingStarted.Eagerly, emptySet())

    // ── Display data ─────────────────────────────────────────────

    internal val _displayNotes = MutableStateFlow<List<FeedNote>>(emptyList())
    val displayNotes: StateFlow<List<FeedNote>> = _displayNotes.asStateFlow()

    internal val _displayLikedNotes = MutableStateFlow<List<FeedNote>>(emptyList())
    val displayLikedNotes: StateFlow<List<FeedNote>> = _displayLikedNotes.asStateFlow()

    internal val _displayZappedNotes = MutableStateFlow<List<FeedNote>>(emptyList())
    val displayZappedNotes: StateFlow<List<FeedNote>> = _displayZappedNotes.asStateFlow()

    /** noteId -> list of (pubkey, emoji) */
    internal val _reactionMap = MutableStateFlow<Map<String, List<Pair<String, String>>>>(emptyMap())
    val reactionMap: StateFlow<Map<String, List<Pair<String, String>>>> = _reactionMap.asStateFlow()

    /** noteId -> list of (pubkey, amountSats) */
    internal val _zapMap = MutableStateFlow<Map<String, List<Pair<String, Long>>>>(emptyMap())
    val zapMap: StateFlow<Map<String, List<Pair<String, Long>>>> = _zapMap.asStateFlow()

    /** noteId -> created_at of the most recent reaction on it */
    internal val _latestReactionDates = MutableStateFlow<Map<String, Long>>(emptyMap())
    val latestReactionDates: StateFlow<Map<String, Long>> = _latestReactionDates.asStateFlow()

    /** noteId -> list of reposter pubkeys (kind 6 e-tagging the note) */
    internal val _repostMap = MutableStateFlow<Map<String, List<String>>>(emptyMap())
    val repostMap: StateFlow<Map<String, List<String>>> = _repostMap.asStateFlow()

    /** noteId -> list of quoter pubkeys (kind 1 q-tagging the note) */
    internal val _quoteMap = MutableStateFlow<Map<String, List<String>>>(emptyMap())
    val quoteMap: StateFlow<Map<String, List<String>>> = _quoteMap.asStateFlow()

    // ── Connection / loading ─────────────────────────────────────

    internal val _isRefreshing = MutableStateFlow(false)
    val isRefreshing: StateFlow<Boolean> = _isRefreshing.asStateFlow()

    internal val _isLoadingMore = MutableStateFlow(false)
    val isLoadingMore: StateFlow<Boolean> = _isLoadingMore.asStateFlow()

    internal val _connectionStatus = MutableStateFlow("Connecting...")
    val connectionStatus: StateFlow<String> = _connectionStatus.asStateFlow()

    internal val _connectionColor = MutableStateFlow("yellow")
    val connectionColor: StateFlow<String> = _connectionColor.asStateFlow()

    /** Bumped each time a rebuilt list lands, so a filter note can count it. */
    internal val _displayPass = MutableStateFlow(0)
    val displayPass: StateFlow<Int> = _displayPass.asStateFlow()

    internal val _notesHasLoadedOnce = MutableStateFlow(false)
    val notesHasLoadedOnce: StateFlow<Boolean> = _notesHasLoadedOnce.asStateFlow()

    internal val _likesHasLoadedOnce = MutableStateFlow(false)
    val likesHasLoadedOnce: StateFlow<Boolean> = _likesHasLoadedOnce.asStateFlow()

    internal val _zapsHasLoadedOnce = MutableStateFlow(false)
    val zapsHasLoadedOnce: StateFlow<Boolean> = _zapsHasLoadedOnce.asStateFlow()

    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles

    // ── Internal state ───────────────────────────────────────────

    /** All raw events from the local relay (all kinds including 7, 9735). */
    internal val allEvents = mutableListOf<NostrEvent>()
    internal val allEventsMutex = Mutex()
    internal val seenIds = ConcurrentHashMap.newKeySet<String>()

    /** Newest created_at seen — lets resume re-subscribes fetch only the gap. */
    @Volatile
    internal var newestEventCreatedAt = 0L

    // Persistent local relay connections (outbox + inbox)
    internal var outboxClient: WebSocketClient? = null
    internal var inboxClient: WebSocketClient? = null
    // Mac relay connections (outbox + inbox) — the source-of-truth relay shared
    // with the iOS/macOS apps. iOS queries macRelayURL + macRelayURL/inbox in
    // VaultNetworking.performRefresh; mirror that here so all devices converge on
    // the same data instead of each showing its own independently-built inbox.
    internal var macOutboxClient: WebSocketClient? = null
    internal var macInboxClient: WebSocketClient? = null
    internal var clientJobs = mutableListOf<Job>()
    internal var isFullReload = false

    internal val zapReceiptCache = ConcurrentHashMap<String, ParsedZapReceipt>()
    internal val requestedMissingIds = ConcurrentHashMap.newKeySet<String>()
    internal val requestedMissingZapNoteIds = ConcurrentHashMap.newKeySet<String>()
    internal var hasFetchedZapReceipts = false

    /**
     * Zaps > Given from the wallet's payment history (NWC): the posts it paid,
     * newest payment first, with the sats and when. Most zap receipts never
     * tag the sender, so relays alone left Given empty (iOS #294).
     */
    internal data class WalletGiven(
        val notes: List<FeedNote> = emptyList(),
        val amounts: Map<String, Long> = emptyMap(),
        val times: Map<String, Long> = emptyMap(),
    )
    @Volatile internal var walletGiven = WalletGiven()
    /** Account + wallet the history was read for; null until it was. */
    @Volatile internal var walletGivenKey: String? = null
    /** Bumped on account switch, so a read still running for the previous account is dropped. */
    @Volatile internal var walletGivenGen = 0
    internal val _walletGivenLoading = MutableStateFlow(false)
    val walletGivenLoading: StateFlow<Boolean> = _walletGivenLoading.asStateFlow()

    internal var updateJob: Job? = null
    internal var updateGeneration = 0
    internal var maxDisplayedItems = 50

    /** How many rows a list shows before "load more"; a count this big is a cap. */
    val pageSize: Int get() = maxDisplayedItems
    /** Notes that passed the Notes filter on the last rebuild, before the cap. */
    @Volatile internal var notesFilteredCount = 0

    // Bounded settle for the Zaps view: guarantees the spinner gives up within
    // ~6s and shows the empty state instead of "loading zaps" forever when the
    // owner simply has no zaps yet. Armed on entering Zaps / changing its filter.
    internal var zapsSettleJob: Job? = null
    internal var likesSettleJob: Job? = null
    init {
        restoreSavedMode()
        loadStats()

        // A new trust graph or follow changes who counts as outside your
        // network, without waiting for other events (iOS followCount).
        viewModelScope.launch {
            kotlinx.coroutines.flow.combine(feedService.wotPubkeys, feedService.followedPubkeys) { _, _ -> }
                .drop(1)
                .collect { scheduleUpdateDisplayData() }
        }

        // Restore disk snapshot immediately — show cached events before the relay is ready
        viewModelScope.launch {
            val restored = restoreSnapshotIfAvailable()
            if (restored) {
                _notesHasLoadedOnce.value = true
                updateDisplayData(updateGeneration)
                Log.d(TAG, "Vault snapshot restored: ${allEvents.size} events")
            }
        }

        // Wait for readyForConnections (fires 500ms after RUNNING) before
        // establishing WebSocket connections to the local relay.
        viewModelScope.launch {
            RelayForegroundService.readyForConnections.collect { ready ->
                Log.d(TAG, "readyForConnections=$ready, notesLoaded=${_notesHasLoadedOnce.value}, color=${_connectionColor.value}")
                if (ready && (!_notesHasLoadedOnce.value || _connectionColor.value == "red")) {
                    connectToLocalRelay()
                }
            }
        }

        // Live fill-in: the relay's importer writes inbound events (replies,
        // reactions, zaps, reposts) straight to its DBs -- open REQ
        // subscriptions are never notified. When the log poller spots an
        // import ("in your inbox" / "in your chat relay"), re-send the
        // subscriptions so the new events stream in without pull-to-refresh.
        viewModelScope.launch {
            RelayForegroundService.inboxActivityTick.drop(1).collectLatest {
                delay(1_500)  // let the import burst settle; restarts on further activity
                resendVaultSubscriptions()
            }
        }

        // Status display: update connection UI text during lifecycle transitions
        viewModelScope.launch {
            RelayForegroundService.relayStatus.collect { status ->
                when (status) {
                    RelayForegroundService.RelayStatus.BOOTING -> {
                        _connectionStatus.value = "Relay booting..."
                        _connectionColor.value = "yellow"
                    }
                    RelayForegroundService.RelayStatus.IMPORTING -> {
                        _connectionStatus.value = "Importing notes..."
                        _connectionColor.value = "yellow"
                    }
                    RelayForegroundService.RelayStatus.RUNNING -> {
                        // Don't connect here -- wait for readyForConnections
                        if (!_notesHasLoadedOnce.value) {
                            _connectionStatus.value = "Relay starting..."
                            _connectionColor.value = "yellow"
                        }
                    }
                    RelayForegroundService.RelayStatus.OFFLINE -> {
                        if (!_notesHasLoadedOnce.value) {
                            _connectionStatus.value = "Relay offline"
                            _connectionColor.value = "red"
                        }
                    }
                }
            }
        }

        // Observe NostrService event updates (from fetchNotesByIds / fetchZapReceipts)
        viewModelScope.launch {
            nostrService.eventUpdates.collect {
                // Merge any new events from NostrService into our allEvents
                mergeNostrServiceEvents()
                scheduleUpdateDisplayData()
            }
        }

        // allEvents (this ViewModel's own event store, separate from NostrService's)
        // had no account-switch observer at all — same class of bug as FeedService's
        // missing forceReload() wiring. Without this, the Relay/Vault tab kept showing
        // the previous account's notes/reactions/zaps mixed in with the new account's.
        viewModelScope.launch {
            configStore.accountSwitches.collect { resetForAccountSwitch() }
        }

        // A list is marked seen when you leave it as well as when you arrive,
        // so what came in while you watched doesn't light its dot later.
        // Coming back from the Media half is arriving: the dot clears then,
        // not while Media hid the list.
        viewModelScope.launch {
            kotlinx.coroutines.flow.combine(
                _viewMode, _noteScope, com.nostrvault.ui.navigation.VaultSection.showsMedia,
            ) { _, _, _ -> watchedMode() }
                .distinctUntilChanged()
                .collect { watched ->
                    val left = lastWatched
                    lastWatched = watched
                    left?.let { markListViewed(it) }
                    watched?.let { markListViewed(it) }
                }
        }

        // Zaps Only drops a Likes dot lit before it came on, so turning the
        // mode off again doesn't bring back a stale one.
        viewModelScope.launch {
            configStore.config.map { it.zapsOnlyMode }.distinctUntilChanged().collect { zapsOnly ->
                if (zapsOnly) _newActivity.value = _newActivity.value - VaultViewMode.LIKES
            }
        }

        // Blocking someone (this tab's Block User, the feed, Settings) drops
        // their notes here on the next pass, as iOS's vault does.
        viewModelScope.launch {
            configStore.config
                .map { it.blockedForActiveAccount() }
                .distinctUntilChanged()
                .drop(1)
                .collect {
                    scheduleUpdateDisplayData()
                    refreshFollowers()
                }
        }
    }

    /** Clears all per-account event state and reconnects fresh. See init{}'s observer. */
    private fun resetForAccountSwitch() {
        disconnectFromLocalRelay()
        viewModelScope.launch {
            allEventsMutex.withLock { allEvents.clear() }
            seenIds.clear()
            forgetGivenLookups()
            walletGivenGen++
            walletGivenKey = null
            walletGiven = WalletGiven()
            _walletGivenLoading.value = false
            newestEventCreatedAt = 0L
            updateGeneration++
            _notesHasLoadedOnce.value = false
            _likesHasLoadedOnce.value = false
            if (_viewMode.value == VaultViewMode.LIKES) armLikesSettle()
            _zapsHasLoadedOnce.value = false
            _displayNotes.value = emptyList()
            _displayLikedNotes.value = emptyList()
            _displayZappedNotes.value = emptyList()
            _reactionMap.value = emptyMap()
            _zapMap.value = emptyMap()
            _repostMap.value = emptyMap()
            _quoteMap.value = emptyMap()
            _followerSnapshot.value = null
            _hasNewFollowers.value = false
            dotBaselineJob?.cancel()
            dotBaselineJob = null
            dotSeenAt.clear()
            _newActivity.value = emptySet()
            olderGeneration++
            olderCursors.clear()
            _noOlderPages.value = emptySet()
            _isLoadingOlder.value = false
            refreshFollowers()
            connectToLocalRelay()
        }
    }

    /**
     * Called when the app returns to the foreground.
     * Re-sends subscriptions on existing connections or reconnects if dropped.
     */
    fun onResume() {
        // Surface cached data immediately — don't wait for new events
        if (allEvents.isNotEmpty()) {
            _notesHasLoadedOnce.value = true
            scheduleUpdateDisplayData()
        }

        val relayUp = RelayForegroundService.relayStatus.value == RelayForegroundService.RelayStatus.RUNNING
        val relayReady = RelayForegroundService.readyForConnections.value
        if (!relayUp || !relayReady) {
            loadStats()
            return
        }

        // Match iOS's incremental refresh on appear: ask the embedded relay to
        // pull newly tagged events from the network. Any imports it makes then
        // trigger the inboxActivityTick re-subscribe, so they fill in live.
        runCatching { com.nostrvault.relay.HavenBridge.requestRelaySync() }
            .onFailure { Log.w(TAG, "requestRelaySync failed: ${it.message}") }

        if (resendVaultSubscriptions()) {
            // Already connected — subscriptions re-sent to catch up on missed events
        } else if (outboxClient != null) {
            // Connection dropped — give auto-reconnect a fresh retry budget
            outboxClient?.resetReconnect()
            inboxClient?.resetReconnect()
            macOutboxClient?.resetReconnect()
            macInboxClient?.resetReconnect()
        } else {
            // No clients at all — full connect
            connectToLocalRelay()
        }

        loadStats()
    }

    override fun onCleared() {
        super.onCleared()
        persistSnapshot()
        disconnectFromLocalRelay()
    }

    // ── Stats ────────────────────────────────────────────────────

    fun loadStats() {
        viewModelScope.launch {
            _statsLoading.value = true
            val stats = statsService.fetchStats()
            _totalEvents.value = stats.totalEvents
            RelayForegroundService.updateEventsStored(stats.totalEvents)
            _storageUsed.value = stats.formattedTotalSize
            _noteCount.value = stats.noteCount
            _dmCount.value = stats.dmCount
            _mediaCount.value = stats.mediaFileCount
            _mediaSize.value = stats.formattedMediaSize
            _statsLoading.value = false
        }
    }

    // ── Import / Export ─────────────────────────────────────────

    /** The "Vault" list is on screen: every list's own dot clears (iOS #506). */
    fun markAllListsViewed() {
        VaultDots.eventLists.forEach(::markListViewed)
    }

    fun persistSnapshot() {
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val dir = configStore.config.value.appSupportDir ?: return@launch
                val events = allEventsMutex.withLock {
                    allEvents.sortedByDescending { it.createdAt }.take(SNAPSHOT_MAX_EVENTS)
                }
                if (events.isEmpty()) return@launch
                val snapshot = DiskVaultSnapshot(
                    events = events,
                    savedAt = System.currentTimeMillis(),
                )
                File(dir, SNAPSHOT_FILE).writeText(json.encodeToString(snapshot))
            } catch (e: Exception) {
                Log.w(TAG, "Vault snapshot save failed: ${e.message}")
            }
        }
    }

    /** The Vault pill's pick. Media only flips the tab's half; the lists keep their state. */
    fun selectMode(mode: VaultMode) {
        mode.noteScope?.let { setNoteScope(it) }
        mode.viewMode?.let { if (_viewMode.value != it) setViewMode(it) }
        com.nostrvault.ui.navigation.VaultSection.show(media = mode == VaultMode.MEDIA)
        if (allRelaysFinished() && activeRelayUrls.isNotEmpty()) loadFirstPageInScope()
    }

    /**
     * Re-reads the ledger every minute while the Relay tab is on screen. A new
     * follow reaches the relay's ledger live, so this is what keeps the list
     * and the red dot semi-realtime. Cancelled by the caller.
     */
    suspend fun pollFollowers() {
        while (currentCoroutineContext().isActive) {
            refreshFollowers()
            delay(FOLLOWERS_POLL_MS)
        }
    }

    /** Reloads the ledger, refreshes the red dot and asks for the profiles the list shows. */
    suspend fun refreshFollowers() {
        val owner = nostrService.activeHexPubkey
        val snapshot = withContext(Dispatchers.IO) {
            FollowerSnapshot.parse(com.nostrvault.relay.HavenBridge.getFollowers(owner))
                ?.without(feedService.blockedHexForActiveAccount())
        } ?: return
        if (owner != nostrService.activeHexPubkey) return
        _followerSnapshot.value = snapshot
        if (watchedMode() == VaultViewMode.FOLLOWERS) {
            markFollowersSeen()
        } else {
            _hasNewFollowers.value = snapshot.hasNewSince(followersSeenStore.seenAt(owner))
        }
        fetchFollowerProfiles()
    }

    /** Events fetched by id for a notification tap, when not (yet) in [allEvents]. */
    internal val focusEvents = ConcurrentHashMap<String, NostrEvent>()

    /** Ids to look for in the list, best first; see [NotificationTarget.focusCandidates]. */
    suspend fun focusCandidates(request: RelayFocusRequest): List<String> =
        NotificationTarget.focusCandidates(request.eventId, focusEvent(request.eventId)?.tags.orEmpty())

    fun profileFor(pubkey: String): FeedProfile? = profiles.value[pubkey]

    fun currentUserPubkey(): String = nostrService.activeHexPubkey

    /** NIP-56 report of a Relay-tab note. The caller also blocks the author, as iOS's UGCReportingDialog does. */
    fun reportNote(noteId: String, pubkey: String, reason: String, description: String) {
        nostrService.reportEvent(noteId, pubkey, reason, description.ifBlank { null })
    }

    fun isWhitelisted(pubkey: String): Boolean =
        resolveWhitelistedHexPubkeys().contains(pubkey)

}

@kotlinx.serialization.Serializable
data class DiskVaultSnapshot(
    val events: List<com.nostrvault.service.NostrEvent>,
    val savedAt: Long,
)
