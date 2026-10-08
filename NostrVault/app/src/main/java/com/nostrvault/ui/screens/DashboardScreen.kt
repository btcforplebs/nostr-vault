package com.nostrvault.ui.screens

import android.content.Intent
import android.util.Log
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.animateScrollBy
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.repeatOnLifecycle
import androidx.lifecycle.viewModelScope
import coil.compose.AsyncImage
import com.nostrvault.ui.navigation.FloatingButtonRow
import com.nostrvault.ui.navigation.FloatingButtonRow.floatingRowButton
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
import com.nostrvault.ui.components.CustomZapSheet
import com.nostrvault.ui.components.GlassPill
import com.nostrvault.ui.components.GlassScaffold
import com.nostrvault.ui.components.reactionDisplayEmoji
import com.nostrvault.ui.components.reactionEmojiSummary
import com.nostrvault.ui.components.ScrollCondenseEffect
import com.nostrvault.ui.components.blockedWhen
import com.nostrvault.ui.components.chromeFab
import com.nostrvault.ui.components.rememberChromeFolded
import com.nostrvault.ui.components.SkeletonFeed
import com.nostrvault.ui.components.VaultNoteCard
import com.nostrvault.ui.components.VaultNoteLayoutMode
import com.nostrvault.ui.components.VaultNoteType
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.components.formatTimestamp
import com.nostrvault.ui.navigation.NotificationTarget
import com.nostrvault.ui.navigation.RelayFocus
import com.nostrvault.ui.navigation.RelayFocusRequest
import com.nostrvault.ui.navigation.Screen
import com.nostrvault.ui.navigation.TabReselect
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
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import java.io.File
import java.text.NumberFormat
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject

/** What the Relay tab counts as a post: notes, reposts, articles, NIP-22
 *  comments, highlights and NIP-88 polls. Comments and highlights that tag you
 *  were never requested, so they never showed up there. iOS:
 *  NostrService.relayTabNoteKinds. */
private val RELAY_TAB_NOTE_KINDS = setOf(1, 6, 30023, NIP10Thread.COMMENT_KIND, 9802, NIP88Poll.KIND)

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
    private val followersSeenStore: com.nostrvault.data.local.FollowersSeenStore,
    private val blossomService: com.nostrvault.service.BlossomService,
    private val feedService: com.nostrvault.service.FeedService,
    private val nwcService: NWCService,
    private val zapHistoryService: ZapHistoryService,
) : ViewModel() {

    /** The shared Blossom mirror run behind "Import Blossom" (iOS MirrorService). */
    val blossomMirrorRun = blossomService.mirrorRun

    fun importBlossom() { blossomService.runMirror() }

    companion object {
        private const val TAG = "DashboardVM"
        private const val MAX_LOCAL_NOTES = 500
        private const val LOAD_TIMEOUT_MS = 15_000L
        private const val LOAD_MORE_TIMEOUT_MS = 8_000L
        // High bound so the relay tab scrolls back through (effectively) full history.
        private const val MAX_ALL_EVENTS = 10_000
        private const val ALL_EVENTS_TRIM_SLACK = 200
        private const val MAX_SEEN_IDS = 10_000
        private const val MAX_ZAP_RECEIPT_CACHE = 500
        /** Zaps > Given reads the wallet's 200 most recent payments. */
        private const val WALLET_GIVEN_PAGES = 4
        private const val WALLET_GIVEN_PAGE_SIZE = 50
        private const val SNAPSHOT_MAX_EVENTS = 500
        private const val SNAPSHOT_MAX_AGE_MS = 24 * 60 * 60 * 1000L // 24 hours
        private const val SNAPSHOT_FILE = "vault_snapshot.json"
        private const val FOLLOWERS_POLL_MS = 60_000L
    }

    private val json = Json { ignoreUnknownKeys = true }

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

    private val _isImporting = MutableStateFlow(false)
    val isImporting = _isImporting.asStateFlow()

    private val _importProgress = MutableStateFlow(0f)
    val importProgress = _importProgress.asStateFlow()

    private val _importStatusMessage = MutableStateFlow("")
    val importStatusMessage = _importStatusMessage.asStateFlow()

    private val _importCompleted = MutableStateFlow(false)
    val importCompleted = _importCompleted.asStateFlow()

    private val _isExportingJsonl = MutableStateFlow(false)
    val isExportingJsonl = _isExportingJsonl.asStateFlow()

    private val _isExportingMedia = MutableStateFlow(false)
    val isExportingMedia = _isExportingMedia.asStateFlow()

    private val _exportUri = MutableStateFlow<android.net.Uri?>(null)
    val exportUri = _exportUri.asStateFlow()

    // ── EOSE tracking per relay ──────────────────────────────────
    private val relayEoseReceived = ConcurrentHashMap<String, Boolean>()
    private val activeRelayUrls = mutableSetOf<String>()

    // ── View mode & filters ──────────────────────────────────────

    private val _viewMode = MutableStateFlow(VaultViewMode.NOTES)
    val viewMode: StateFlow<VaultViewMode> = _viewMode.asStateFlow()

    private val _contentFilter = MutableStateFlow(VaultContentFilter.ALL)
    val contentFilter: StateFlow<VaultContentFilter> = _contentFilter.asStateFlow()

    private val _likesFilter = MutableStateFlow(VaultLikesFilter.ON_MY_NOTES)
    val likesFilter: StateFlow<VaultLikesFilter> = _likesFilter.asStateFlow()

    private val _zapsFilter = MutableStateFlow(VaultZapsFilter.ON_MY_NOTES)
    val zapsFilter: StateFlow<VaultZapsFilter> = _zapsFilter.asStateFlow()

    private val _followersFilter = MutableStateFlow(VaultFollowersFilter.NEW)
    val followersFilter: StateFlow<VaultFollowersFilter> = _followersFilter.asStateFlow()

    // ── Followers (relay follower ledger, iOS #136) ──────────────

    /** Null while the relay is stopped or the ledger hasn't opened yet. */
    private val _followerSnapshot = MutableStateFlow<FollowerSnapshot?>(null)
    val followerSnapshot: StateFlow<FollowerSnapshot?> = _followerSnapshot.asStateFlow()

    /** Red dot on the Followers mode button: follows since the owner last looked. */
    private val _hasNewFollowers = MutableStateFlow(false)
    val hasNewFollowers: StateFlow<Boolean> = _hasNewFollowers.asStateFlow()

    // ── Display data ─────────────────────────────────────────────

    private val _displayNotes = MutableStateFlow<List<FeedNote>>(emptyList())
    val displayNotes: StateFlow<List<FeedNote>> = _displayNotes.asStateFlow()

    private val _displayLikedNotes = MutableStateFlow<List<FeedNote>>(emptyList())
    val displayLikedNotes: StateFlow<List<FeedNote>> = _displayLikedNotes.asStateFlow()

    private val _displayZappedNotes = MutableStateFlow<List<FeedNote>>(emptyList())
    val displayZappedNotes: StateFlow<List<FeedNote>> = _displayZappedNotes.asStateFlow()

    /** noteId -> list of (pubkey, emoji) */
    private val _reactionMap = MutableStateFlow<Map<String, List<Pair<String, String>>>>(emptyMap())
    val reactionMap: StateFlow<Map<String, List<Pair<String, String>>>> = _reactionMap.asStateFlow()

    /** noteId -> list of (pubkey, amountSats) */
    private val _zapMap = MutableStateFlow<Map<String, List<Pair<String, Long>>>>(emptyMap())
    val zapMap: StateFlow<Map<String, List<Pair<String, Long>>>> = _zapMap.asStateFlow()

    /** noteId -> created_at of the most recent reaction on it */
    private val _latestReactionDates = MutableStateFlow<Map<String, Long>>(emptyMap())
    val latestReactionDates: StateFlow<Map<String, Long>> = _latestReactionDates.asStateFlow()

    /** noteId -> list of reposter pubkeys (kind 6 e-tagging the note) */
    private val _repostMap = MutableStateFlow<Map<String, List<String>>>(emptyMap())
    val repostMap: StateFlow<Map<String, List<String>>> = _repostMap.asStateFlow()

    /** noteId -> list of quoter pubkeys (kind 1 q-tagging the note) */
    private val _quoteMap = MutableStateFlow<Map<String, List<String>>>(emptyMap())
    val quoteMap: StateFlow<Map<String, List<String>>> = _quoteMap.asStateFlow()

    // ── Connection / loading ─────────────────────────────────────

    private val _isRefreshing = MutableStateFlow(false)
    val isRefreshing: StateFlow<Boolean> = _isRefreshing.asStateFlow()

    private val _isLoadingMore = MutableStateFlow(false)
    val isLoadingMore: StateFlow<Boolean> = _isLoadingMore.asStateFlow()

    private val _connectionStatus = MutableStateFlow("Connecting...")
    val connectionStatus: StateFlow<String> = _connectionStatus.asStateFlow()

    private val _connectionColor = MutableStateFlow("yellow")
    val connectionColor: StateFlow<String> = _connectionColor.asStateFlow()

    private val _notesHasLoadedOnce = MutableStateFlow(false)
    val notesHasLoadedOnce: StateFlow<Boolean> = _notesHasLoadedOnce.asStateFlow()

    private val _likesHasLoadedOnce = MutableStateFlow(false)
    val likesHasLoadedOnce: StateFlow<Boolean> = _likesHasLoadedOnce.asStateFlow()

    private val _zapsHasLoadedOnce = MutableStateFlow(false)
    val zapsHasLoadedOnce: StateFlow<Boolean> = _zapsHasLoadedOnce.asStateFlow()

    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles

    // ── Internal state ───────────────────────────────────────────

    /** All raw events from the local relay (all kinds including 7, 9735). */
    private val allEvents = mutableListOf<NostrEvent>()
    private val allEventsMutex = Mutex()
    private val seenIds = ConcurrentHashMap.newKeySet<String>()

    /** Newest created_at seen — lets resume re-subscribes fetch only the gap. */
    @Volatile
    private var newestEventCreatedAt = 0L

    // Persistent local relay connections (outbox + inbox)
    private var outboxClient: WebSocketClient? = null
    private var inboxClient: WebSocketClient? = null
    // Mac relay connections (outbox + inbox) — the source-of-truth relay shared
    // with the iOS/macOS apps. iOS queries macRelayURL + macRelayURL/inbox in
    // VaultNetworking.performRefresh; mirror that here so all devices converge on
    // the same data instead of each showing its own independently-built inbox.
    private var macOutboxClient: WebSocketClient? = null
    private var macInboxClient: WebSocketClient? = null
    private var clientJobs = mutableListOf<Job>()
    private var isFullReload = false

    private val zapReceiptCache = ConcurrentHashMap<String, ParsedZapReceipt>()
    private val requestedMissingIds = ConcurrentHashMap.newKeySet<String>()
    private val requestedMissingZapNoteIds = ConcurrentHashMap.newKeySet<String>()
    private var hasFetchedZapReceipts = false

    /**
     * Zaps > Given from the wallet's payment history (NWC): the posts it paid,
     * newest payment first, with the sats and when. Most zap receipts never
     * tag the sender, so relays alone left Given empty (iOS #294).
     */
    private data class WalletGiven(
        val notes: List<FeedNote> = emptyList(),
        val amounts: Map<String, Long> = emptyMap(),
        val times: Map<String, Long> = emptyMap(),
    )
    @Volatile private var walletGiven = WalletGiven()
    /** Account + wallet the history was read for; null until it was. */
    @Volatile private var walletGivenKey: String? = null
    /** Bumped on account switch, so a read still running for the previous account is dropped. */
    @Volatile private var walletGivenGen = 0
    private val _walletGivenLoading = MutableStateFlow(false)
    val walletGivenLoading: StateFlow<Boolean> = _walletGivenLoading.asStateFlow()

    private var updateJob: Job? = null
    private var updateGeneration = 0
    private var maxDisplayedItems = 50
    /** Notes that passed the Notes filter on the last rebuild, before the cap. */
    @Volatile private var notesFilteredCount = 0

    // Bounded settle for the Zaps view: guarantees the spinner gives up within
    // ~6s and shows the empty state instead of "loading zaps" forever when the
    // owner simply has no zaps yet. Armed on entering Zaps / changing its filter.
    private var zapsSettleJob: Job? = null
    private fun armZapsSettle() {
        zapsSettleJob?.cancel()
        zapsSettleJob = viewModelScope.launch {
            delay(6000)
            _zapsHasLoadedOnce.value = true
        }
    }

    init {
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
            configStore.config
                .map { it.activeAccountNpub }
                .distinctUntilChanged()
                .drop(1) // Skip initial emission
                .collect { resetForAccountSwitch() }
        }

        // Blocking someone (this tab's Block User, the feed, Settings) drops
        // their notes here on the next pass, as iOS's vault does.
        viewModelScope.launch {
            configStore.config
                .map { it.blockedForActiveAccount() }
                .distinctUntilChanged()
                .drop(1)
                .collect { scheduleUpdateDisplayData() }
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

    fun importNotes(context: android.content.Context) {
        if (_isImporting.value) return
        if (configStore.config.value.useExternalRelay) {
            _importStatusMessage.value = com.nostrvault.service.EXTERNAL_RELAY_IMPORT_MESSAGE
            return
        }
        _isImporting.value = true
        _importProgress.value = 0f
        _importStatusMessage.value = "Preparing import..."
        _importCompleted.value = false

        viewModelScope.launch {
            try {
                // Stop relay first
                RelayForegroundService.stop(context)
                delay(2000)

                // Start in import mode
                withContext(Dispatchers.IO) {
                    val config = configStore.config.value
                    val relayDataDir = java.io.File(context.filesDir, "relay_data")
                    val envDict = com.nostrvault.relay.RelayConfiguration.generateEnvDictionary(
                        config = config,
                        relayDataDir = relayDataDir,
                    )
                    for ((key, value) in envDict) {
                        com.nostrvault.relay.HavenBridge.setEnv(key, value)
                    }
                    com.nostrvault.relay.HavenBridge.startRelay(importMode = true)
                }

                // Poll for progress
                val batch = com.nostrvault.relay.RelayLogParser.BatchedStateUpdate()
                while (!batch.importCompleted && !batch.stopImporting) {
                    val logLine = withContext(Dispatchers.IO) {
                        com.nostrvault.relay.HavenBridge.getImportLog()
                    }
                    if (!logLine.isNullOrBlank()) {
                        batch.importProgress = null
                        batch.importStatusMessage = null
                        com.nostrvault.relay.RelayLogParser.collectStateChanges(logLine, batch)
                        batch.importProgress?.let { _importProgress.value = it.toFloat() }
                        batch.importStatusMessage?.let { _importStatusMessage.value = it }
                    }
                    delay(200)
                }

                _importProgress.value = 1f
                _importStatusMessage.value = "Import Complete!"
                _importCompleted.value = true
            } catch (e: Exception) {
                _importStatusMessage.value = "Import failed: ${e.message}"
                _importCompleted.value = true
            } finally {
                _isImporting.value = false
                // Restart relay normally
                RelayForegroundService.start(context)
            }
        }
    }

    fun exportJsonl(context: android.content.Context) {
        if (_isExportingJsonl.value) return
        _isExportingJsonl.value = true

        viewModelScope.launch {
            try {
                val outputDir = java.io.File(context.cacheDir, "exports")
                outputDir.mkdirs()
                val outputFile = java.io.File(outputDir, "haven_backup_${System.currentTimeMillis()}.zip")

                val result = withContext(Dispatchers.IO) {
                    com.nostrvault.relay.HavenBridge.backupDatabase(outputFile.absolutePath)
                }

                if (result == 0 && outputFile.exists()) {
                    val uri = androidx.core.content.FileProvider.getUriForFile(
                        context,
                        "${context.packageName}.fileprovider",
                        outputFile,
                    )
                    val intent = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                        type = "application/zip"
                        putExtra(android.content.Intent.EXTRA_STREAM, uri)
                        addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    context.startActivity(android.content.Intent.createChooser(intent, "Export Database"))
                }
            } catch (e: Exception) {
                Log.e(TAG, "JSONL export failed: ${e.message}")
            } finally {
                _isExportingJsonl.value = false
            }
        }
    }

    fun exportMedia(context: android.content.Context) {
        if (_isExportingMedia.value) return
        _isExportingMedia.value = true

        viewModelScope.launch {
            try {
                val config = configStore.config.value
                val blossomDir = config.relayDataDir?.let { "$it/${config.blossomPath}" }
                if (blossomDir == null) {
                    _isExportingMedia.value = false
                    return@launch
                }

                val outputDir = java.io.File(context.cacheDir, "exports")
                outputDir.mkdirs()
                val outputFile = java.io.File(outputDir, "haven_media_${System.currentTimeMillis()}.zip")

                val result = withContext(Dispatchers.IO) {
                    com.nostrvault.relay.HavenBridge.zipDirectory(blossomDir, outputFile.absolutePath)
                }

                if (result == 0 && outputFile.exists()) {
                    val uri = androidx.core.content.FileProvider.getUriForFile(
                        context,
                        "${context.packageName}.fileprovider",
                        outputFile,
                    )
                    val intent = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                        type = "application/zip"
                        putExtra(android.content.Intent.EXTRA_STREAM, uri)
                        addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    context.startActivity(android.content.Intent.createChooser(intent, "Export Media"))
                }
            } catch (e: Exception) {
                Log.e(TAG, "Media export failed: ${e.message}")
            } finally {
                _isExportingMedia.value = false
            }
        }
    }

    fun dismissImport() {
        _importCompleted.value = false
        _importProgress.value = 0f
        _importStatusMessage.value = ""
    }

    // ── Local relay notes ────────────────────────────────────────

    // ── Local relay notes (persistent connections) ──────────────

    /**
     * Thin wrapper for pull-to-refresh. Full reload clears state.
     */
    fun loadLocalRelayNotes() {
        // Pull-to-refresh: ask the embedded relay to fetch newly tagged events
        // (replies, reactions, zaps, reposts, mentions, DMs) and the owner's own
        // notes from external relays into the local DBs. Injected events then
        // stream in over the local subscription opened below. Non-blocking.
        runCatching { com.nostrvault.relay.HavenBridge.requestRelaySync() }
            .onFailure { Log.w(TAG, "requestRelaySync failed: ${it.message}") }

        // Keep existing data and only fetch new events (don't clear or full reload)
        _isRefreshing.value = true
        // Ask again for liked and zapped posts that are still missing.
        forgetGivenLookups()
        when (_viewMode.value) {
            VaultViewMode.LIKES -> fetchMissingLikedNotes()
            VaultViewMode.ZAPS -> {
                fetchMoreZapReceipts()
                fetchMissingZappedNotes()
            }
            else -> {}
        }

        // Reuse live sockets: re-send the since-bounded subscriptions instead of
        // tearing every connection down and replaying the whole window. Only
        // rebuild connections when they're actually gone/dead.
        if (!resendVaultSubscriptions()) {
            connectToLocalRelay()
        }
    }

    /**
     * Re-sends the vault subscriptions on live connections so events the relay
     * imported since the last REQ stream in (the importer writes straight to
     * its DBs and never notifies open subscriptions). Returns false when the
     * local connections aren't up — caller decides whether to reconnect.
     */
    private fun resendVaultSubscriptions(): Boolean {
        val outboxUp = outboxClient?.connectionState?.value == WebSocketClient.ConnectionState.CONNECTED
        val inboxUp = inboxClient?.connectionState?.value == WebSocketClient.ConnectionState.CONNECTED
        if (!outboxUp || !inboxUp) return false

        val authors = buildAuthorSet()
        val ownerHex = nostrService.activeHexPubkey
        val config = configStore.config.value
        val localUrl = config.nostrURL ?: return false
        val inboxUrl = config.localInboxURL ?: return false
        val macWss = config.macRelayWssURL

        outboxClient?.let { sendVaultSubscription(it, "vault-outbox", authors, ownerHex, localUrl) }
        inboxClient?.let { sendVaultSubscription(it, "vault-inbox", authors, ownerHex, inboxUrl) }
        // Re-pull the Mac relay (source of truth) too so we converge on its data
        macOutboxClient?.takeIf { it.connectionState.value == WebSocketClient.ConnectionState.CONNECTED }
            ?.let { sendVaultSubscription(it, "vault-mac-outbox", authors, ownerHex, macWss) }
        macInboxClient?.takeIf { it.connectionState.value == WebSocketClient.ConnectionState.CONNECTED }
            ?.let { sendVaultSubscription(it, "vault-mac-inbox", authors, ownerHex, "$macWss/inbox") }
        return true
    }

    /**
     * Creates persistent WebSocket connections to the local relay (outbox + inbox).
     * Message collectors feed into shared allEvents; subscriptions are sent
     * automatically when the connection reaches CONNECTED state.
     */
    private fun connectToLocalRelay() {
        val config = configStore.config.value
        if (config.nostrURL == null) {
            _connectionStatus.value = "No local relay"
            _connectionColor.value = "red"
            return
        }
        val localUrl = config.nostrURL ?: return
        val inboxUrl = config.localInboxURL ?: return
        val ownerHex = nostrService.activeHexPubkey
        val authors = buildAuthorSet()

        Log.d(TAG, "connectToLocalRelay: outbox=$localUrl, inbox=$inboxUrl, authors=${authors.size}, fullReload=$isFullReload")

        disconnectFromLocalRelay()

        _connectionStatus.value = "Connecting..."
        _connectionColor.value = "yellow"

        // --- Outbox connection ---
        val outbox = WebSocketClient(url = localUrl, scope = viewModelScope, trustLocalhost = true)
        outboxClient = outbox

        val outboxMsgJob = viewModelScope.launch(Dispatchers.IO) {
            outbox.messages.collect { msg -> processRelayMessage(msg, localUrl) }
        }
        val outboxStateJob = viewModelScope.launch {
            outbox.connectionState.collect { state ->
                when (state) {
                    WebSocketClient.ConnectionState.CONNECTED -> {
                        sendVaultSubscription(outbox, "vault-outbox", authors, ownerHex, localUrl)
                        updateConnectionStatus()
                    }
                    WebSocketClient.ConnectionState.DISCONNECTED -> updateConnectionStatus()
                    else -> {}
                }
            }
        }

        // --- Inbox connection ---
        val inbox = WebSocketClient(url = inboxUrl, scope = viewModelScope, trustLocalhost = true)
        inboxClient = inbox

        val inboxMsgJob = viewModelScope.launch(Dispatchers.IO) {
            inbox.messages.collect { msg -> processRelayMessage(msg, inboxUrl) }
        }
        val inboxStateJob = viewModelScope.launch {
            inbox.connectionState.collect { state ->
                when (state) {
                    WebSocketClient.ConnectionState.CONNECTED -> {
                        sendVaultSubscription(inbox, "vault-inbox", authors, ownerHex, inboxUrl)
                        updateConnectionStatus()
                    }
                    WebSocketClient.ConnectionState.DISCONNECTED -> updateConnectionStatus()
                    else -> {}
                }
            }
        }

        val jobs = mutableListOf(outboxMsgJob, outboxStateJob, inboxMsgJob, inboxStateJob)

        // --- Mac relay connections (source-of-truth, shared with iOS/macOS) ---
        // Real cert on a public domain → normal system trust (trustLocalhost = false).
        // The inbox relay requires no AUTH to query, so a plain REQ returns the
        // tagged replies/reactions/zaps the local embedded relay hasn't imported yet.
        val macWss = config.macRelayWssURL
        if (macWss.isNotEmpty()) {
            val macInboxUrl = "$macWss/inbox"
            Log.d(TAG, "connectToLocalRelay: mac outbox=$macWss, mac inbox=$macInboxUrl")

            val macOutbox = WebSocketClient(url = macWss, scope = viewModelScope, trustLocalhost = false)
            macOutboxClient = macOutbox
            jobs += viewModelScope.launch(Dispatchers.IO) {
                macOutbox.messages.collect { msg -> processRelayMessage(msg, macWss) }
            }
            jobs += viewModelScope.launch {
                macOutbox.connectionState.collect { state ->
                    when (state) {
                        WebSocketClient.ConnectionState.CONNECTED ->
                            sendVaultSubscription(macOutbox, "vault-mac-outbox", authors, ownerHex, macWss)
                        else -> {}
                    }
                }
            }

            val macInbox = WebSocketClient(url = macInboxUrl, scope = viewModelScope, trustLocalhost = false)
            macInboxClient = macInbox
            jobs += viewModelScope.launch(Dispatchers.IO) {
                macInbox.messages.collect { msg -> processRelayMessage(msg, macInboxUrl) }
            }
            jobs += viewModelScope.launch {
                macInbox.connectionState.collect { state ->
                    when (state) {
                        WebSocketClient.ConnectionState.CONNECTED ->
                            sendVaultSubscription(macInbox, "vault-mac-inbox", authors, ownerHex, macInboxUrl)
                        else -> {}
                    }
                }
            }
        }

        clientJobs = jobs
        outbox.connect()
        inbox.connect()
        macOutboxClient?.connect()
        macInboxClient?.connect()
    }

    /**
     * Sends a Nostr REQ subscription on an existing connection.
     */
    private fun sendVaultSubscription(
        client: WebSocketClient,
        subId: String,
        authors: Set<String>,
        ownerHex: String,
        relayUrl: String,
    ) {
        // Track this relay as active and reset EOSE tracking
        activeRelayUrls.add(relayUrl)
        relayEoseReceived[relayUrl] = false

        val authorsJson = authors.joinToString(",") { "\"$it\"" }
        // Always cap the stored-event replay. Without a limit the relay dumps the
        // entire vault history on every connect. When we already hold events
        // (resume re-subscribe), only ask for the gap since the newest one.
        val newest = newestEventCreatedAt
        val sinceClause = if (!isFullReload && newest > 0) ",\"since\":${newest - 60}" else ""

        val authorFilter = """{"kinds":[1,6,7,30023,1111,9802,9735,1068],"authors":[$authorsJson]$sinceClause,"limit":500}"""

        val filters = if (ownerHex.isNotEmpty()) {
            // IMPORTANT: Mentions filter should NOT use sinceClause - we want ALL notes
            // where the user is tagged, not just recent ones. This fixes the bug where
            // older tagged notes never appear in the TAGGED filter.
            val mentionsFilter = """{"kinds":[1,6,7,30023,1111,9802,9735,1068],"#p":["$ownerHex"],"limit":500}"""
            "$authorFilter,$mentionsFilter"
        } else {
            authorFilter
        }

        Log.d(TAG, "sendVaultSubscription: subId=$subId, fullReload=$isFullReload")
        client.send("""["REQ","$subId",$filters]""")
    }

    /**
     * Processes a single relay message from either the outbox or inbox connection.
     * Deduplicates via seenIds, routes metadata to NostrService, accumulates
     * content events into allEvents, and schedules a display update.
     */
    private suspend fun processRelayMessage(msg: String, relayUrl: String) {
        try {
            val parsed = json.parseToJsonElement(msg).jsonArray
            val type = parsed[0].jsonPrimitive.contentOrNull ?: return

            when (type) {
                "EVENT" -> {
                    if (parsed.size < 3) return
                    val eventObj = parsed[2].jsonObject
                    val id = eventObj["id"]?.jsonPrimitive?.contentOrNull ?: return
                    if (!seenIds.add(id)) return

                    val pubkey = eventObj["pubkey"]?.jsonPrimitive?.contentOrNull ?: return
                    val kind = eventObj["kind"]?.jsonPrimitive?.intOrNull ?: return
                    val content = eventObj["content"]?.jsonPrimitive?.contentOrNull ?: ""
                    val createdAt = eventObj["created_at"]?.jsonPrimitive?.longOrNull ?: return
                    val sig = eventObj["sig"]?.jsonPrimitive?.contentOrNull ?: ""
                    val tags = eventObj["tags"]?.jsonArray?.map { tagArr ->
                        tagArr.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" }
                    } ?: emptyList()

                    // Metadata events go to NostrService
                    if (kind in listOf(0, 10002, 10050, 10063, 10000)) {
                        nostrService.processRelayMessage(msg, relayUrl)
                        return
                    }

                    // NIP-57: a zap receipt is spoofable by anyone who can reach a relay
                    // we query — only trust it if it came from the pubkey the recipient's
                    // own LNURL endpoint designates as authorized to publish on their behalf.
                    if (kind == 9735) {
                        val recipientPubkey = tags.firstOrNull { it.size >= 2 && it[0] == "p" }?.get(1)
                        if (recipientPubkey == null || !ZapValidationService.isValidReceipt(
                                receiptPubkey = pubkey,
                                recipientPubkey = recipientPubkey,
                                profiles = nostrService.profiles.value,
                            )
                        ) {
                            return
                        }
                    }

                    val nostrEvent = NostrEvent(
                        id = id,
                        pubkey = pubkey,
                        createdAt = createdAt,
                        kind = kind,
                        tags = tags,
                        content = content,
                        sig = sig,
                    )

                    allEventsMutex.withLock {
                        allEvents.add(nostrEvent)
                        trimAllEventsLocked()
                    }
                    // Future-dated junk must not poison the resume catch-up window
                    val nowSecs = System.currentTimeMillis() / 1000
                    if (createdAt > newestEventCreatedAt && createdAt <= nowSecs + 60) {
                        newestEventCreatedAt = createdAt
                    }

                    if (seenIds.size > MAX_SEEN_IDS) {
                        val retained = allEventsMutex.withLock { allEvents.mapTo(HashSet()) { it.id } }
                        seenIds.retainAll(retained)
                        seenIds.add(id)
                    }

                    nostrService.fetchMissingProfiles(listOf(pubkey))
                    scheduleUpdateDisplayData()
                }
                "EOSE" -> {
                    if (parsed.size >= 2) {
                        val subId = parsed[1].jsonPrimitive.contentOrNull
                        val eventCount = allEventsMutex.withLock { allEvents.size }
                        Log.d(TAG, "EOSE received from $relayUrl, subId=$subId, total events loaded: $eventCount")

                        // Track that this relay has sent EOSE
                        relayEoseReceived[relayUrl] = true

                        // If all connected relays have sent EOSE, finalize loading
                        if (allRelaysFinished()) {
                            handleEOSE()
                        }
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Parse error: ${e.message}")
        }
    }

    /** Caller must hold [allEventsMutex]. Trims oldest events past the cap. */
    private fun trimAllEventsLocked() {
        if (allEvents.size > MAX_ALL_EVENTS + ALL_EVENTS_TRIM_SLACK) {
            allEvents.sortByDescending { it.createdAt }
            allEvents.subList(MAX_ALL_EVENTS, allEvents.size).clear()
        }
    }

    /**
     * Checks if all connected relays have sent EOSE.
     */
    private fun allRelaysFinished(): Boolean {
        // If no relays are active, consider it finished
        if (activeRelayUrls.isEmpty()) return true

        // Check if all active relays have sent EOSE
        return activeRelayUrls.all { url ->
            relayEoseReceived[url] == true
        }
    }

    /**
     * Called when all relays have sent EOSE (end of stored events).
     * Updates connection state and stops the refresh spinner.
     */
    private fun handleEOSE() {
        viewModelScope.launch(Dispatchers.Main.immediate) {
            _isRefreshing.value = false
            _notesHasLoadedOnce.value = true
            isFullReload = false
            updateConnectionStatus()
            // All stored events are in — bypass the debounce
            updateJob?.cancel()
            updateGeneration++
            updateDisplayData(updateGeneration)
        }
    }

    // ── Connection helpers ────────────────────────────────────────

    private fun disconnectFromLocalRelay() {
        clientJobs.forEach { it.cancel() }
        clientJobs.clear()
        outboxClient?.disconnect()
        inboxClient?.disconnect()
        macOutboxClient?.disconnect()
        macInboxClient?.disconnect()
        outboxClient = null
        inboxClient = null
        macOutboxClient = null
        macInboxClient = null

        // Clear EOSE tracking state
        activeRelayUrls.clear()
        relayEoseReceived.clear()
    }

    // ── Snapshot persistence ─────────────────────────────────────

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

    private suspend fun restoreSnapshotIfAvailable(): Boolean = withContext(Dispatchers.IO) {
        try {
            val dir = configStore.config.value.appSupportDir ?: return@withContext false
            val file = File(dir, SNAPSHOT_FILE)
            if (!file.exists()) return@withContext false

            val snapshot = json.decodeFromString<DiskVaultSnapshot>(file.readText())
            if (System.currentTimeMillis() - snapshot.savedAt > SNAPSHOT_MAX_AGE_MS) {
                file.delete()
                return@withContext false
            }

            allEventsMutex.withLock {
                for (event in snapshot.events) {
                    allEvents.add(event)
                    seenIds.add(event.id)
                }
                newestEventCreatedAt = allEvents.maxOfOrNull { it.createdAt } ?: 0L
            }
            true
        } catch (e: Exception) {
            Log.w(TAG, "Vault snapshot restore failed: ${e.message}")
            false
        }
    }

    private fun buildAuthorSet(): Set<String> {
        val config = configStore.config.value
        val authors = mutableSetOf<String>()
        val ownerHex = nostrService.activeHexPubkey
        if (ownerHex.isNotEmpty()) authors.add(ownerHex)
        config.whitelistedNpubs?.forEach { npub ->
            nostrService.npubToHex(npub)?.let { authors.add(it) }
        }
        return authors
    }

    private fun updateConnectionStatus() {
        val outboxConnected = outboxClient?.connectionState?.value == WebSocketClient.ConnectionState.CONNECTED
        val inboxConnected = inboxClient?.connectionState?.value == WebSocketClient.ConnectionState.CONNECTED
        when {
            outboxConnected && inboxConnected -> {
                val count = _displayNotes.value.size
                _connectionStatus.value = if (count > 0) "Local ($count)" else "Live"
                _connectionColor.value = "green"
            }
            outboxConnected || inboxConnected -> {
                _connectionStatus.value = "Partial"
                _connectionColor.value = "yellow"
            }
            outboxClient != null -> {
                // Clients exist but not connected yet (connecting/reconnecting)
                _connectionStatus.value = "Connecting..."
                _connectionColor.value = "yellow"
            }
            else -> {
                _connectionStatus.value = "Offline"
                _connectionColor.value = "red"
            }
        }
    }

    fun loadMore() {
        Log.d(TAG, "loadMore called: isLoadingMore=${_isLoadingMore.value}, viewMode=${_viewMode.value}, notesCount=${_displayNotes.value.size}")
        if (_isLoadingMore.value) return
        val currentNotes = _displayNotes.value
        if (currentNotes.isEmpty()) return

        // For notes mode, show more of what is loaded, and pull older notes
        // from the relay once everything loaded is listed. Without raising the
        // cap the list stopped at 50: older notes loaded underneath but never
        // showed (iOS #273).
        if (_viewMode.value == VaultViewMode.NOTES) {
            val hiddenBelowCap = relayNotesHiddenBelowCap(notesFilteredCount, maxDisplayedItems)
            maxDisplayedItems += 50
            if (hiddenBelowCap) {
                scheduleUpdateDisplayData()
                return
            }
            val oldest = currentNotes.lastOrNull()?.createdAt ?: return
            val config = configStore.config.value
            if (config.nostrURL == null) {
                Log.w(TAG, "loadMore: No relay URL configured")
                return
            }
            val localUrl = config.nostrURL ?: return
            val inboxUrl = config.localInboxURL ?: return

            // Build author set matching loadLocalRelayNotes
            val ownerHex = nostrService.activeHexPubkey
            val authors = mutableSetOf<String>()
            if (ownerHex.isNotEmpty()) authors.add(ownerHex)
            config.whitelistedNpubs?.forEach { npub ->
                nostrService.npubToHex(npub)?.let { authors.add(it) }
            }

            _isLoadingMore.value = true

            viewModelScope.launch(Dispatchers.IO) {
                val untilSecs = oldest.time / 1000 - 1
                val authorsJson = authors.joinToString(",") { "\"$it\"" }
                val authorFilter = """{"kinds":[1,6,7,30023,1111,9802,9735,1068],"authors":[$authorsJson],"until":$untilSecs,"limit":200}"""

                val filters = if (ownerHex.isNotEmpty()) {
                    val mentionsFilter = """{"kinds":[1,6,7,30023,1111,9802,9735,1068],"#p":["$ownerHex"],"until":$untilSecs,"limit":300}"""
                    "$authorFilter,$mentionsFilter"
                } else {
                    authorFilter
                }

                // Query outbox
                val (outboxRaw, _) = queryRelayEndpoint(localUrl, filters, "outbox-hist", LOAD_MORE_TIMEOUT_MS)

                // Query inbox for older tagged notes
                val (inboxRaw, _) = queryRelayEndpoint(inboxUrl, filters, "inbox-hist", LOAD_MORE_TIMEOUT_MS)

                allEventsMutex.withLock {
                    allEvents.addAll(outboxRaw)
                    allEvents.addAll(inboxRaw)
                    trimAllEventsLocked()
                }

                withContext(Dispatchers.Main.immediate) {
                    _isLoadingMore.value = false
                }

                scheduleUpdateDisplayData()
            }
        } else {
            // For likes/zaps mode, just increase the display limit
            maxDisplayedItems += 50
            scheduleUpdateDisplayData()
        }
    }

    // ── Mode & filter setters ────────────────────────────────────

    fun setViewMode(mode: VaultViewMode) {
        _viewMode.value = mode
        maxDisplayedItems = 50
        scheduleUpdateDisplayData()
        when (mode) {
            VaultViewMode.LIKES -> fetchMissingLikedNotes()
            VaultViewMode.ZAPS -> {
                armZapsSettle()
                fetchMoreZapReceipts()
                fetchMissingZappedNotes()
            }
            VaultViewMode.FOLLOWERS -> {
                markFollowersSeen()
                viewModelScope.launch { refreshFollowers() }
            }
            else -> {}
        }
    }

    fun setContentFilter(filter: VaultContentFilter) {
        _contentFilter.value = filter
        maxDisplayedItems = 50
        _notesHasLoadedOnce.value = false
        scheduleUpdateDisplayData()
    }

    fun setLikesFilter(filter: VaultLikesFilter) {
        _likesFilter.value = filter
        maxDisplayedItems = 50
        _likesHasLoadedOnce.value = false
        scheduleUpdateDisplayData()
        if (filter == VaultLikesFilter.MY_LIKES) fetchMissingLikedNotes()
    }

    fun setZapsFilter(filter: VaultZapsFilter) {
        _zapsFilter.value = filter
        maxDisplayedItems = 50
        _zapsHasLoadedOnce.value = false
        armZapsSettle()
        scheduleUpdateDisplayData()
        if (filter == VaultZapsFilter.MY_ZAPS) fetchMissingZappedNotes()
    }

    fun setFollowersFilter(filter: VaultFollowersFilter) {
        _followersFilter.value = filter
        fetchFollowerProfiles()
    }

    // ── Followers ────────────────────────────────────────────────

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
        } ?: return
        if (owner != nostrService.activeHexPubkey) return
        _followerSnapshot.value = snapshot
        if (_viewMode.value == VaultViewMode.FOLLOWERS) {
            markFollowersSeen()
        } else {
            _hasNewFollowers.value = snapshot.hasNewSince(followersSeenStore.seenAt(owner))
        }
        fetchFollowerProfiles()
    }

    private fun markFollowersSeen() {
        followersSeenStore.markSeen(nostrService.activeHexPubkey)
        _hasNewFollowers.value = false
    }

    private fun fetchFollowerProfiles() {
        val snapshot = _followerSnapshot.value ?: return
        val shown = snapshot.entries(_followersFilter.value).take(300).map { it.pubkey }
        if (shown.isNotEmpty()) nostrService.fetchMissingProfiles(shown)
    }

    // ── Notification focus (port of iOS consumeRelayFocus, PR #95) ──

    /** Events fetched by id for a notification tap, when not (yet) in [allEvents]. */
    private val focusEvents = ConcurrentHashMap<String, NostrEvent>()

    /**
     * Switch to the list that holds a notification's event: likes → Likes on
     * my notes, zaps → Zaps on my notes, everything else → Notes / All. Filters
     * are only touched when they differ, since setting one resets its list.
     */
    suspend fun applyRelayFocusView(request: RelayFocusRequest, zapsOnly: Boolean) {
        when (NotificationTarget.viewFor(request.type, zapsOnly)) {
            VaultViewMode.LIKES -> {
                if (_likesFilter.value != VaultLikesFilter.ON_MY_NOTES) setLikesFilter(VaultLikesFilter.ON_MY_NOTES)
                if (_viewMode.value != VaultViewMode.LIKES) setViewMode(VaultViewMode.LIKES)
            }
            VaultViewMode.ZAPS -> {
                if (_zapsFilter.value != VaultZapsFilter.ON_MY_NOTES) setZapsFilter(VaultZapsFilter.ON_MY_NOTES)
                if (_viewMode.value != VaultViewMode.ZAPS) setViewMode(VaultViewMode.ZAPS)
            }
            VaultViewMode.NOTES -> {
                // A reply from outside your network isn't listed under All.
                val author = focusEvent(request.eventId)?.pubkey
                val target = if (author != null && VaultContentFilter.isOutside(
                        author, nostrService.activeHexPubkey, resolveWhitelistedHexPubkeys(),
                        feedService.relayTabTrustedPubkeys(),
                    )
                ) VaultContentFilter.OUTSIDE else VaultContentFilter.ALL
                if (_contentFilter.value != target) setContentFilter(target)
                if (_viewMode.value != VaultViewMode.NOTES) setViewMode(VaultViewMode.NOTES)
            }
            VaultViewMode.FOLLOWERS -> {
                if (_viewMode.value != VaultViewMode.FOLLOWERS) setViewMode(VaultViewMode.FOLLOWERS)
                return // a list, not an event: nothing to fetch
            }
        }
        fetchFocusEventIfMissing(request.eventId)
    }

    /**
     * The notification's event carries the target in its tags, so it has to be
     * at hand. It normally arrives over the live inbox subscription; on a cold
     * start that can lag, so also ask the local relays for it by id.
     */
    private fun fetchFocusEventIfMissing(id: String) {
        viewModelScope.launch(Dispatchers.IO) {
            if (focusEvent(id) != null) return@launch
            val config = configStore.config.value
            val urls = listOfNotNull(config.nostrURL, config.localInboxURL).distinct()
            for (url in urls) {
                val (raw, _) = queryRelayEndpoint(
                    url, "{\"ids\":[\"$id\"]}", "focus", LOAD_MORE_TIMEOUT_MS, dedupe = false,
                )
                raw.firstOrNull { it.id == id }?.let {
                    focusEvents[id] = it
                    return@launch
                }
            }
        }
    }

    private suspend fun focusEvent(id: String): NostrEvent? =
        focusEvents[id] ?: allEventsMutex.withLock { allEvents.firstOrNull { it.id == id } }

    /** Ids to look for in the list, best first; see [NotificationTarget.focusCandidates]. */
    suspend fun focusCandidates(request: RelayFocusRequest): List<String> =
        NotificationTarget.focusCandidates(request.eventId, focusEvent(request.eventId)?.tags.orEmpty())

    /**
     * The post to open when the event never shows up in the list (older than
     * the loaded page). Null when the notification's event could not be found,
     * since opening a reaction or zap receipt as a note shows nothing.
     */
    suspend fun focusFallbackNoteId(request: RelayFocusRequest): String? =
        // A mention or reply is a note itself, so its id opens even untagged.
        NotificationTarget.targetNoteId(
            request.type, request.eventId, focusEvent(request.eventId)?.tags.orEmpty(),
        )

    // ── Display data processing (port of iOS VaultDataProcessing) ──

    private fun scheduleUpdateDisplayData() {
        updateJob?.cancel()
        updateGeneration++
        val gen = updateGeneration
        // Longer debounce during the initial stored-event burst; 150ms (matching
        // iOS) once live. EOSE bypasses this entirely via handleEOSE().
        val debounceMs = if (!_notesHasLoadedOnce.value) 500L else 150L
        updateJob = viewModelScope.launch {
            delay(debounceMs)
            if (gen != updateGeneration) return@launch
            updateDisplayData(gen)
            // Likes and zaps that arrive later name more missing posts; ask
            // for those too (iOS re-asks on every events change). Ids already
            // asked for are skipped.
            when (_viewMode.value) {
                VaultViewMode.LIKES -> if (_likesFilter.value == VaultLikesFilter.MY_LIKES) fetchMissingLikedNotes()
                VaultViewMode.ZAPS -> if (_zapsFilter.value == VaultZapsFilter.MY_ZAPS) fetchMissingZappedNotes()
                else -> {}
            }
        }
    }

    private suspend fun updateDisplayData(gen: Int) = withContext(Dispatchers.Default) {
        val currentMode = _viewMode.value
        val events = allEventsMutex.withLock { allEvents.toList() }
        val owner = nostrService.activeHexPubkey
        val whitelist = resolveWhitelistedHexPubkeys()
        val trusted = feedService.relayTabTrustedPubkeys()
        val blocked = configStore.config.value.blockedForActiveAccount()
            .mapNotNull { nostrService.npubToHex(it) }.toSet()

        // Partition once instead of re-scanning the full list per kind.
        // allEvents can hold one event twice (history pages query outbox and
        // inbox, and the snapshot is saved from allEvents); the lists key on
        // id, and a duplicate key crashes the LazyColumn.
        val noteEvents = ArrayList<NostrEvent>(events.size)
        val reactionEvents = ArrayList<NostrEvent>()
        val zapEvents = ArrayList<NostrEvent>()
        val partitionedIds = HashSet<String>(events.size * 2)
        for (event in events) {
            if (!partitionedIds.add(event.id)) continue
            when (event.kind) {
                in RELAY_TAB_NOTE_KINDS -> noteEvents.add(event)
                7 -> reactionEvents.add(event)
                9735 -> zapEvents.add(event)
            }
        }

        when (currentMode) {
            // Followers come from the relay's follower ledger, not these events.
            VaultViewMode.FOLLOWERS -> Unit
            VaultViewMode.NOTES -> {
                val currentFilter = _contentFilter.value

                val filtered = noteEvents.filter { event ->
                    // Log all events before kind filtering to see what we're dropping
                    val hasUserPTag = event.tags.any { it.size >= 2 && it[0] == "p" && it[1] == owner }
                    if (hasUserPTag && event.pubkey != owner) {
                        Log.d(TAG, "Event with user p-tag BEFORE filter: id=${event.id.take(8)}, kind=${event.kind}, from=${event.pubkey.take(8)}")
                    }

                    if (event.kind !in RELAY_TAB_NOTE_KINDS) {
                        if (hasUserPTag && event.pubkey != owner) {
                            Log.w(TAG, "DROPPING event kind ${event.kind} that tags user: id=${event.id.take(8)}")
                        }
                        return@filter false
                    }

                    if (event.pubkey in blocked) return@filter false

                    val isMine = event.pubkey == owner
                    val isTagged = event.tags.any { it.size >= 2 && it[0] == "p" && it[1] == owner }
                    val isOutside = isTagged &&
                        VaultContentFilter.isOutside(event.pubkey, owner, whitelist, trusted)
                    when (currentFilter) {
                        VaultContentFilter.ALL -> {
                            val isWhitelisted = whitelist.contains(event.pubkey)
                            (isMine || isTagged || isWhitelisted) && !isOutside
                        }
                        VaultContentFilter.MINE -> isMine
                        VaultContentFilter.OUTSIDE -> isOutside
                        VaultContentFilter.TAGGED -> {
                            val tagged = !isMine && isTagged && !isOutside
                            if (tagged) {
                                Log.d(TAG, "TAGGED note included: id=${event.id.take(8)}, from=${event.pubkey.take(8)}, kind=${event.kind}")
                            }
                            tagged
                        }
                    }
                }.sortedByDescending { it.createdAt }

                Log.d(TAG, "NOTES mode: filter=${currentFilter.displayName}, total=${filtered.size} notes, maxDisplayedItems=$maxDisplayedItems")
                notesFilteredCount = filtered.size

                // Convert to FeedNote for display
                val displaySlice = filtered.take(maxDisplayedItems).map { event ->
                    FeedNote.fromEvent(event.id, event.pubkey, event.content, event.tags, event.createdAt, event.kind)
                }.filter { !it.isNoiseOrSpam() }

                val droppedBySpamFilter = (filtered.size.coerceAtMost(maxDisplayedItems)) - displaySlice.size
                if (droppedBySpamFilter > 0) {
                    Log.w(TAG, "Spam filter dropped $droppedBySpamFilter notes")
                }
                if (filtered.size > maxDisplayedItems) {
                    Log.w(TAG, "Display limit: showing ${maxDisplayedItems} of ${filtered.size} filtered notes (${filtered.size - maxDisplayedItems} hidden)")
                }

                val displayedIds = displaySlice.map { it.id }.toSet()

                // Build reaction map for displayed notes
                val rxMap = mutableMapOf<String, MutableList<Pair<String, String>>>()
                val latestReaction = mutableMapOf<String, Long>()
                for (event in reactionEvents) {
                    val targetId = event.tags.firstOrNull { it.size >= 2 && it[0] == "e" && displayedIds.contains(it[1]) }?.get(1) ?: continue
                    val emoji = if (event.content.isEmpty()) "+" else event.content
                    rxMap.getOrPut(targetId) { mutableListOf() }.add(Pair(event.pubkey, emoji))
                    val existing = latestReaction[targetId]
                    if (existing == null || event.createdAt > existing) {
                        latestReaction[targetId] = event.createdAt
                    }
                }

                // Build zap map for displayed notes
                val zMap = mutableMapOf<String, MutableList<Pair<String, Long>>>()
                for (event in zapEvents) {
                    val targetId = event.tags.firstOrNull { it.size >= 2 && it[0] == "e" && displayedIds.contains(it[1]) }?.get(1) ?: continue
                    val parsed = parseZapReceipt(event) ?: continue
                    zMap.getOrPut(targetId) { mutableListOf() }.add(Pair(parsed.senderPubkey, parsed.amountSats))
                }

                // Build repost map (kind 6 e-tagging a displayed note) and quote map
                // (kind 1 q-tagging a displayed note). Mirrors iOS VaultDataProcessing
                // so reposts/quotes of your note appear in the engagement bar.
                val rpMap = mutableMapOf<String, MutableList<String>>()
                val qtMap = mutableMapOf<String, MutableList<String>>()
                for (event in noteEvents) {
                    when (event.kind) {
                        6 -> {
                            val targetId = event.tags.firstOrNull { it.size >= 2 && it[0] == "e" && displayedIds.contains(it[1]) }?.get(1) ?: continue
                            rpMap.getOrPut(targetId) { mutableListOf() }.add(event.pubkey)
                        }
                        1 -> {
                            val targetId = event.tags.firstOrNull { it.size >= 2 && it[0] == "q" && displayedIds.contains(it[1]) }?.get(1) ?: continue
                            qtMap.getOrPut(targetId) { mutableListOf() }.add(event.pubkey)
                        }
                    }
                }

                if (gen != updateGeneration) return@withContext
                withContext(Dispatchers.Main.immediate) {
                    _displayNotes.value = displaySlice
                    _reactionMap.value = rxMap
                    _zapMap.value = zMap
                    _latestReactionDates.value = latestReaction
                    _repostMap.value = rpMap
                    _quoteMap.value = qtMap
                    _notesHasLoadedOnce.value = true
                    _connectionStatus.value = "Local (${displaySlice.size})"
                }
            }

            VaultViewMode.LIKES -> {
                val currentLikesFilter = _likesFilter.value

                if (currentLikesFilter == VaultLikesFilter.MY_LIKES) {
                    // My Likes: notes I reacted to
                    val myLikeDates = mutableMapOf<String, Long>()
                    for (event in reactionEvents) {
                        if (event.pubkey != owner) continue
                        val targetId = event.tags.firstOrNull { it.size >= 2 && it[0] == "e" }?.get(1) ?: continue
                        val existing = myLikeDates[targetId]
                        if (existing == null || event.createdAt > existing) {
                            myLikeDates[targetId] = event.createdAt
                        }
                    }

                    val myLikedNoteIds = myLikeDates.keys
                    val filtered = noteEvents
                        .filter { myLikedNoteIds.contains(it.id) }
                        .sortedByDescending { myLikeDates[it.id] ?: 0L }

                    val displaySlice = filtered.take(maxDisplayedItems).map { event ->
                        FeedNote.fromEvent(event.id, event.pubkey, event.content, event.tags, event.createdAt, event.kind)
                    }

                    if (gen != updateGeneration) return@withContext
                    withContext(Dispatchers.Main.immediate) {
                        _displayLikedNotes.value = displaySlice
                        _reactionMap.value = emptyMap()
                        _latestReactionDates.value = emptyMap()
                        if (displaySlice.isNotEmpty()) _likesHasLoadedOnce.value = true
                    }
                } else {
                    // Incoming reactions on target note sets
                    // Received: reactions others left on my notes.
                    val targetNoteIds: Set<String> =
                        noteEvents.filter { it.pubkey == owner }.map { it.id }.toSet()

                    val rxMap = mutableMapOf<String, MutableList<Pair<String, String>>>()
                    val latestReaction = mutableMapOf<String, Long>()

                    for (event in reactionEvents) {
                        if (event.pubkey == owner) continue
                        val targetId = event.tags.firstOrNull {
                            it.size >= 2 && it[0] == "e" && targetNoteIds.contains(it[1])
                        }?.get(1) ?: continue
                        val emoji = if (event.content.isEmpty()) "+" else event.content
                        rxMap.getOrPut(targetId) { mutableListOf() }.add(Pair(event.pubkey, emoji))
                        val existing = latestReaction[targetId]
                        if (existing == null || event.createdAt > existing) {
                            latestReaction[targetId] = event.createdAt
                        }
                    }

                    val likedNoteIds = rxMap.keys
                    val filtered = noteEvents
                        .filter { likedNoteIds.contains(it.id) }
                        .sortedWith(compareByDescending<NostrEvent> { latestReaction[it.id] ?: 0L }
                            .thenByDescending { it.createdAt })

                    val displaySlice = filtered.take(maxDisplayedItems).map { event ->
                        FeedNote.fromEvent(event.id, event.pubkey, event.content, event.tags, event.createdAt, event.kind)
                    }

                    if (gen != updateGeneration) return@withContext
                    withContext(Dispatchers.Main.immediate) {
                        _displayLikedNotes.value = displaySlice
                        _reactionMap.value = rxMap
                        _latestReactionDates.value = latestReaction
                        if (displaySlice.isNotEmpty()) _likesHasLoadedOnce.value = true
                    }
                }
            }

            VaultViewMode.ZAPS -> {
                val currentZapsFilter = _zapsFilter.value

                // Parse all zap receipts (with caching)
                data class ParsedEntry(val receiptId: String, val parsed: ParsedZapReceipt)
                val parsedReceipts = mutableListOf<ParsedEntry>()
                for (receipt in zapEvents) {
                    val parsed = parseZapReceipt(receipt) ?: continue
                    parsedReceipts.add(ParsedEntry(receipt.id, parsed))
                }

                // Both lists run newest zap first: a post moves to the top
                // when a zap on it comes in (iOS #296).
                val receiptTimes = zapEvents.associate { it.id to it.createdAt }

                if (currentZapsFilter == VaultZapsFilter.MY_ZAPS) {
                    val myReceipts = parsedReceipts
                        .filter { it.parsed.senderPubkey == owner && it.parsed.requestIsSigned }
                    // Receipts on the relays, plus what this app recorded
                    // zapping from this phone.
                    // Stream and profile zaps record a non-note key; only event ids count.
                    val locallyZapped = feedService.zappedEventIds.value.filterKeys(RelayGiven::isEventId)
                    val myZappedNoteIds = myReceipts.mapNotNull { it.parsed.targetNoteId }.toSet() + locallyZapped.keys
                    val wallet = walletGiven

                    // The wallet's history, then anything only a receipt or
                    // this app's own list knows about.
                    val seen = wallet.notes.map { it.id }.toHashSet()
                    val candidates = wallet.notes + noteEvents
                        .filter { myZappedNoteIds.contains(it.id) && seen.add(it.id) }
                        .map { event -> FeedNote.fromEvent(event.id, event.pubkey, event.content, event.tags, event.createdAt, event.kind) }
                    val lastZapAt = RelayGiven.lastZapTimes(
                        wallet.times,
                        myReceipts.mapNotNull { item ->
                            val id = item.parsed.targetNoteId ?: return@mapNotNull null
                            id to (receiptTimes[item.receiptId] ?: return@mapNotNull null)
                        },
                    )
                    val filtered = RelayGiven.newestZapFirst(candidates, lastZapAt, { it.id }, { it.createdAt.time / 1000 })
                    val displaySlice = filtered.take(maxDisplayedItems)
                    val givenMap = RelayGiven.givenAmounts(locallyZapped, wallet.amounts)
                        .mapValues { (_, sats) -> listOf(owner to sats) }

                    if (gen != updateGeneration) return@withContext
                    withContext(Dispatchers.Main.immediate) {
                        _displayZappedNotes.value = displaySlice
                        _zapMap.value = givenMap
                        if (displaySlice.isNotEmpty()) _zapsHasLoadedOnce.value = true
                    }
                } else {
                    // Incoming zaps on target note sets
                    // Received: zaps others sent to my notes.
                    val targetNoteIds: Set<String> =
                        noteEvents.filter { it.pubkey == owner }.map { it.id }.toSet()

                    val zMap = mutableMapOf<String, MutableList<Pair<String, Long>>>()
                    val lastZapAt = mutableMapOf<String, Long>()

                    for (item in parsedReceipts) {
                        val targetId = item.parsed.targetNoteId ?: continue
                        if (!targetNoteIds.contains(targetId)) continue
                        if (item.parsed.senderPubkey == owner) continue
                        zMap.getOrPut(targetId) { mutableListOf() }.add(Pair(item.parsed.senderPubkey, item.parsed.amountSats))
                        lastZapAt[targetId] = maxOf(lastZapAt[targetId] ?: 0L, receiptTimes[item.receiptId] ?: 0L)
                    }

                    val zappedNoteIds = zMap.keys
                    val filtered = RelayGiven.newestZapFirst(
                        noteEvents.filter { zappedNoteIds.contains(it.id) },
                        lastZapAt,
                        { it.id },
                        { it.createdAt },
                    )

                    val displaySlice = filtered.take(maxDisplayedItems).map { event ->
                        FeedNote.fromEvent(event.id, event.pubkey, event.content, event.tags, event.createdAt, event.kind)
                    }

                    if (gen != updateGeneration) return@withContext
                    withContext(Dispatchers.Main.immediate) {
                        _displayZappedNotes.value = displaySlice
                        _zapMap.value = zMap
                        if (displaySlice.isNotEmpty()) _zapsHasLoadedOnce.value = true
                    }
                }
            }
        }
    }

    // ── External relay fetching (port of iOS VaultNetworking) ────

    private fun fetchMissingLikedNotes() {
        val owner = nostrService.activeHexPubkey
        if (owner.isEmpty()) return

        viewModelScope.launch(Dispatchers.Default) {
            val events = allEventsMutex.withLock { allEvents.toList() }

            val myLikes = events.filter { it.kind == 7 && it.pubkey == owner }
            val likedAuthor = HashMap<String, String>()
            val likedNoteIds = HashSet<String>()
            for (like in myLikes) {
                val target = like.tags.firstOrNull { it.size >= 2 && it[0] == "e" }?.get(1) ?: continue
                likedNoteIds.add(target)
                like.tags.firstOrNull { it.size >= 2 && it[0] == "p" }?.get(1)?.let { likedAuthor[target] = it }
            }

            val existingIds = events.map { it.id }.toSet()
            val missingIds = likedNoteIds.subtract(existingIds).subtract(requestedMissingIds)
            if (missingIds.isEmpty()) return@launch

            for (id in missingIds) requestedMissingIds.add(id)
            Log.d(TAG, "Fetching ${missingIds.size} missing liked notes")

            // You mostly like posts from the feed, which already holds them
            // signed and whole: take those now instead of waiting on relays
            // (iOS #295: primal returned 7 of the last 20 liked posts).
            for (id in missingIds) {
                val event = feedService.getCachedRawEvent(id)?.let(RelayGiven::eventFromJson) ?: continue
                if (event.id == id) nostrService.injectEvent(event)
            }

            val config = configStore.config.value
            val relayUrls = RelayGiven.likedNoteRelays(
                localRoot = config.nostrURL,
                localFeed = config.localRelayURL("feed"),
                feedRelays = config.activeFeedRelays,
                missingIds = missingIds,
                likedAuthor = likedAuthor,
                outboxRelays = nostrService.outboxRelays.value,
            )
            nostrService.fetchNotesByIds(missingIds.toList(), relayUrls)
        }
    }

    private fun fetchMissingZappedNotes() {
        viewModelScope.launch(Dispatchers.Default) {
            val events = allEventsMutex.withLock { allEvents.toList() }
            val zapReceipts = events.filter { it.kind == 9735 }

            val targetNoteIds = mutableSetOf<String>()
            for (receipt in zapReceipts) {
                val cached = zapReceiptCache[receipt.id]
                if (cached != null) {
                    cached.targetNoteId?.let { targetNoteIds.add(it) }
                } else {
                    val targetId = receipt.tags.firstOrNull { it.size >= 2 && it[0] == "e" }?.get(1)
                    if (targetId != null) targetNoteIds.add(targetId)
                }
            }

            // Posts this app zapped from this phone, for Given (iOS #296).
            targetNoteIds.addAll(feedService.zappedEventIds.value.keys.filter(RelayGiven::isEventId))

            val existingIds = events.map { it.id }.toSet()
            val missingIds = targetNoteIds.subtract(existingIds).subtract(requestedMissingZapNoteIds)
            if (missingIds.isEmpty()) return@launch

            for (id in missingIds) requestedMissingZapNoteIds.add(id)
            Log.d(TAG, "Fetching ${missingIds.size} missing zapped notes")

            val relayUrls = buildExternalRelayUrls()
            nostrService.fetchNotesByIds(missingIds.toList(), relayUrls)
        }
    }

    private fun fetchMoreZapReceipts() {
        fetchGivenZapsFromWallet()
        if (hasFetchedZapReceipts) return
        hasFetchedZapReceipts = true

        val localUrl = configStore.config.value.nostrURL ?: return
        val urls = listOfNotNull(localUrl, configStore.config.value.localInboxURL).distinct()
        Log.d(TAG, "Fetching extended zap receipts history")
        nostrService.fetchZapReceipts(urls)

        // Your relay only holds receipts that tag you with `p`, i.e. zaps you
        // received. The receipt for a zap you sent is published to the relays
        // of the person you zapped and tags you with `P`, so "Given" stayed
        // empty. Ask the feed relays for those.
        val owner = nostrService.activeHexPubkey
        if (owner.isNotEmpty()) {
            // Your published inbox too: zaps sent from here ask for receipts there.
            val externalUrls = (buildExternalRelayUrls() + nostrService.relayLists.value[owner].orEmpty())
                .filter { it != localUrl }
                .distinctBy { it.lowercase() }
            nostrService.fetchZapReceipts(externalUrls, limit = 500, tagFilter = mapOf("#P" to listOf(owner)))
        }
    }

    /** Lets a refresh or account switch ask again for posts still missing. */
    private fun forgetGivenLookups() {
        requestedMissingIds.clear()
        requestedMissingZapNoteIds.clear()
        hasFetchedZapReceipts = false
    }

    /**
     * Zaps > Given from the wallet: the zaps the connected NWC wallet paid,
     * matched to their posts the same way the wallet's own history is. Read
     * once per account and wallet; a pull-to-refresh does not redo it.
     */
    private fun fetchGivenZapsFromWallet() {
        val owner = nostrService.activeHexPubkey
        val nwcURI = configStore.config.value.nwcURI
        if (owner.isEmpty() || nwcURI.isNullOrBlank() || _walletGivenLoading.value) return
        val key = "$owner|$nwcURI"
        if (walletGivenKey == key) return
        walletGivenKey = key
        walletGiven = WalletGiven()
        _walletGivenLoading.value = true
        val gen = walletGivenGen
        fun stillCurrent() = walletGivenGen == gen && walletGivenKey == key

        viewModelScope.launch(Dispatchers.IO) {
            try {
                val sent = mutableListOf<WalletTransaction>()
                for (page in 0 until WALLET_GIVEN_PAGES) {
                    val txs = try {
                        nwcService.listTransactions(limit = WALLET_GIVEN_PAGE_SIZE, offset = page * WALLET_GIVEN_PAGE_SIZE)
                    } catch (e: Exception) {
                        // Unsupported or unreachable: try again on the next visit.
                        Log.w(TAG, "Wallet history for Given failed: ${e.message}")
                        if (page == 0 && stillCurrent()) walletGivenKey = null
                        break
                    }
                    sent += txs.filter {
                        it.direction == WalletTransaction.Direction.OUTGOING &&
                            it.state == WalletTransaction.State.SETTLED
                    }
                    if (txs.size < WALLET_GIVEN_PAGE_SIZE) break
                }
                if (!stillCurrent() || sent.isEmpty()) return@launch

                val found = zapHistoryService.lookup(sent, owner)
                if (!stillCurrent()) return@launch
                val notes = mutableListOf<FeedNote>()
                val amounts = HashMap<String, Long>()
                val times = HashMap<String, Long>()
                for (tx in sent.sortedByDescending { it.createdAt }) {
                    val postId = found.details[tx.id]?.postId ?: continue
                    val note = found.posts[postId] ?: continue
                    if (postId !in amounts) {
                        notes.add(note)
                        times[postId] = tx.createdAt
                    }
                    amounts[postId] = (amounts[postId] ?: 0L) + tx.amountSats
                }
                walletGiven = WalletGiven(notes, amounts, times)
            } finally {
                if (walletGivenGen == gen) {
                    _walletGivenLoading.value = false
                    scheduleUpdateDisplayData()
                }
            }
        }
    }

    /** Merge events from NostrService.events into our allEvents store. */
    private suspend fun mergeNostrServiceEvents() {
        val serviceEvents = nostrService.events
        allEventsMutex.withLock {
            val existingIds = allEvents.map { it.id }.toHashSet()
            for (event in serviceEvents) {
                // seenIds too: the live subscription marks an event seen before
                // it reaches allEvents, so checking allEvents alone let one
                // arriving on both paths be added twice.
                // Every kind the tab lists, so a liked or zapped comment or
                // highlight fetched for Given is kept.
                if ((event.kind in RELAY_TAB_NOTE_KINDS || event.kind == 7 || event.kind == 9735) &&
                    existingIds.add(event.id) && seenIds.add(event.id)) {
                    allEvents.add(event)
                }
            }
            trimAllEventsLocked()
        }
    }

    // ── Helpers ──────────────────────────────────────────────────

    private fun buildExternalRelayUrls(): List<String> {
        val urls = mutableListOf<String>()
        configStore.config.value.nostrURL?.let { urls.add(it) }
        urls.addAll(configStore.config.value.readRelays)
        return urls
    }

    private fun resolveWhitelistedHexPubkeys(): Set<String> {
        return configStore.config.value.whitelistedNpubs
            ?.mapNotNull { nostrService.npubToHex(it) }
            ?.toSet() ?: emptySet()
    }

    private fun parseZapReceipt(event: NostrEvent): ParsedZapReceipt? {
        zapReceiptCache[event.id]?.let { return it }

        val descJson = event.tags.firstOrNull { it.size >= 2 && it[0] == "description" }?.get(1) ?: return null
        try {
            val zapReq = json.parseToJsonElement(descJson).jsonObject
            val senderPubkey = zapReq["pubkey"]?.jsonPrimitive?.contentOrNull ?: return null
            val reqTags = zapReq["tags"]?.jsonArray
            // The note comes from the signed request, not the receipt: a forged
            // receipt can wrap your real request and point it at another note.
            val requestTargetId = reqTags?.firstNotNullOfOrNull { tag ->
                val tagArr = tag as? JsonArray ?: return@firstNotNullOfOrNull null
                if (tagArr.size >= 2 && (tagArr[0] as? JsonPrimitive)?.contentOrNull == "e") (tagArr[1] as? JsonPrimitive)?.contentOrNull else null
            }
            val targetId = requestTargetId ?: event.tags.firstOrNull { it.size >= 2 && it[0] == "e" }?.get(1)

            // The request's `amount` tag is optional (NIP-57); the paid invoice is not.
            val amountSats = com.nostrvault.util.ZapAmount.sats(event.tags)

            val parsed = ParsedZapReceipt(senderPubkey, targetId, amountSats, com.nostrvault.relay.HavenBridge.verifyEvent(descJson))
            zapReceiptCache[event.id] = parsed
            if (zapReceiptCache.size > MAX_ZAP_RECEIPT_CACHE) {
                val toRemove = zapReceiptCache.keys.take(zapReceiptCache.size - MAX_ZAP_RECEIPT_CACHE)
                toRemove.forEach { zapReceiptCache.remove(it) }
            }
            return parsed
        } catch (_: Exception) {
            return null
        }
    }

    fun profileFor(pubkey: String): FeedProfile? = profiles.value[pubkey]

    fun currentUserPubkey(): String = nostrService.activeHexPubkey

    /** NIP-56 report of a Relay-tab note. The caller also blocks the author, as iOS's UGCReportingDialog does. */
    fun reportNote(noteId: String, pubkey: String, reason: String, description: String) {
        nostrService.reportEvent(noteId, pubkey, reason, description.ifBlank { null })
    }

    fun isWhitelisted(pubkey: String): Boolean =
        resolveWhitelistedHexPubkeys().contains(pubkey)

    /**
     * Query a relay endpoint, collecting events until EOSE or timeout.
     * Uses the shared [seenIds] set to deduplicate across calls.
     */
    private suspend fun queryRelayEndpoint(
        url: String,
        filters: String,
        subIdPrefix: String,
        timeoutMs: Long,
        /** False for lookups that must not mark ids as seen: a seen id is
         *  dropped by the live subscription, so it would never reach the list. */
        dedupe: Boolean = true,
    ): Pair<List<NostrEvent>, List<FeedNote>> {
        val rawEvents = mutableListOf<NostrEvent>()
        val contentNotes = mutableListOf<FeedNote>()
        val client = WebSocketClient(url = url, scope = viewModelScope, trustLocalhost = true)
        val subId = "$subIdPrefix-${UUID.randomUUID().toString().take(8)}"
        var eoseReceived = false

        val collectJob = viewModelScope.launch(Dispatchers.IO) {
            client.messages.collect { msg ->
                try {
                    val parsed = json.parseToJsonElement(msg).jsonArray
                    val type = parsed[0].jsonPrimitive.contentOrNull ?: return@collect

                    when (type) {
                        "EVENT" -> {
                            if (parsed.size < 3) return@collect
                            val eventObj = parsed[2].jsonObject
                            val id = eventObj["id"]?.jsonPrimitive?.contentOrNull ?: return@collect
                            if (dedupe && !seenIds.add(id)) return@collect

                            val pubkey = eventObj["pubkey"]?.jsonPrimitive?.contentOrNull ?: return@collect
                            val kind = eventObj["kind"]?.jsonPrimitive?.intOrNull ?: return@collect
                            val content = eventObj["content"]?.jsonPrimitive?.contentOrNull ?: ""
                            val createdAt = eventObj["created_at"]?.jsonPrimitive?.longOrNull ?: return@collect
                            val sig = eventObj["sig"]?.jsonPrimitive?.contentOrNull ?: ""
                            val tags = eventObj["tags"]?.jsonArray?.map { tagArr ->
                                tagArr.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" }
                            } ?: emptyList()

                            if (kind in listOf(0, 10002, 10050, 10063, 10000)) {
                                nostrService.processRelayMessage(msg, url)
                                return@collect
                            }

                            val nostrEvent = NostrEvent(
                                id = id, pubkey = pubkey, createdAt = createdAt,
                                kind = kind, tags = tags, content = content, sig = sig,
                            )
                            rawEvents.add(nostrEvent)

                            if (kind in RELAY_TAB_NOTE_KINDS) {
                                val note = FeedNote.fromEvent(id, pubkey, content, tags, createdAt, kind)
                                if (!note.isNoiseOrSpam()) {
                                    contentNotes.add(note)
                                }
                            }

                            nostrService.fetchMissingProfiles(listOf(pubkey))
                        }
                        "EOSE" -> {
                            eoseReceived = true
                        }
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "Parse error in $subIdPrefix: ${e.message}")
                }
            }
        }

        client.connect()

        var waited = 0L
        while (client.connectionState.value != WebSocketClient.ConnectionState.CONNECTED && waited < 5000) {
            delay(100)
            waited += 100
        }

        if (client.connectionState.value == WebSocketClient.ConnectionState.CONNECTED) {
            val sent = client.send("[\"REQ\",\"$subId\",$filters]")
            if (sent) {
                val deadline = System.currentTimeMillis() + timeoutMs
                while (!eoseReceived && System.currentTimeMillis() < deadline) {
                    delay(200)
                }
            }
        }

        collectJob.cancel()
        client.disconnect()

        return Pair(rawEvents, contentNotes)
    }

}

// ═══════════════════════════════════════════════════════════════════
// IconFilterButton composable
// ═══════════════════════════════════════════════════════════════════

/**
 * Icon toggle for the Relay tab's pills. With a [label], the selected button
 * also says its word (iOS #135), so a row of icons still tells you which
 * filter is on. [showDot] puts a red dot on its corner.
 */
@Composable
private fun IconFilterButton(
    icon: ImageVector,
    contentDescription: String,
    isSelected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    label: String? = null,
    showDot: Boolean = false,
) {
    val colors = LocalNostrVaultColors.current
    val tint by animateColorAsState(
        targetValue = if (isSelected) colors.primary else SecondaryText,
        animationSpec = Motion.control(),
        label = "filterTint",
    )
    Box(modifier = modifier.defaultMinSize(minWidth = 36.dp, minHeight = 36.dp)) {
        if (isSelected && label != null) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(5.dp),
                modifier = Modifier
                    .align(Alignment.Center)
                    .height(32.dp)
                    .clip(CircleShape)
                    .background(colors.primary.copy(alpha = 0.16f))
                    .clickable(onClickLabel = contentDescription, onClick = onClick)
                    .padding(horizontal = 10.dp),
            ) {
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    tint = tint,
                    modifier = Modifier.size(18.dp),
                )
                Text(
                    text = label,
                    color = tint,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    softWrap = false,
                )
            }
        } else {
            IconButton(
                onClick = onClick,
                modifier = Modifier.size(36.dp).align(Alignment.Center),
            ) {
                Icon(
                    imageVector = icon,
                    contentDescription = contentDescription,
                    tint = tint,
                    modifier = Modifier.size(20.dp),
                )
            }
        }
        AnimatedVisibility(
            visible = showDot,
            enter = scaleIn() + fadeIn(),
            exit = scaleOut() + fadeOut(),
            modifier = Modifier
                .align(Alignment.TopEnd)
                .offset(x = (-5).dp, y = 6.dp),
        ) {
            Box(Modifier.size(8.dp).background(ErrorRed, CircleShape))
        }
    }
}

/**
 * The trailing pill's filters for [viewMode]. Notes: All · Mine · Mentions · Outside.
 * Likes and Zaps: Received · Given. Followers: New · All.
 */
@Composable
private fun RelayFilterPill(
    viewMode: VaultViewMode,
    contentFilter: VaultContentFilter,
    likesFilter: VaultLikesFilter,
    zapsFilter: VaultZapsFilter,
    followersFilter: VaultFollowersFilter,
    viewModel: DashboardViewModel,
    labelled: Boolean,
) {
    GlassPill {
        @Composable
        fun filter(icon: ImageVector, name: String, selected: Boolean, onClick: () -> Unit) =
            IconFilterButton(
                icon = icon,
                contentDescription = name,
                isSelected = selected,
                onClick = onClick,
                label = if (labelled) name else null,
            )
        when (viewMode) {
            VaultViewMode.NOTES -> {
                filter(NostrVaultIcons.Layers, VaultContentFilter.ALL.displayName, contentFilter == VaultContentFilter.ALL) {
                    viewModel.setContentFilter(VaultContentFilter.ALL)
                }
                filter(NostrVaultIcons.Profile, VaultContentFilter.MINE.displayName, contentFilter == VaultContentFilter.MINE) {
                    viewModel.setContentFilter(VaultContentFilter.MINE)
                }
                filter(NostrVaultIcons.At, VaultContentFilter.TAGGED.displayName, contentFilter == VaultContentFilter.TAGGED) {
                    viewModel.setContentFilter(VaultContentFilter.TAGGED)
                }
                filter(NostrVaultIcons.OutsideNetwork, VaultContentFilter.OUTSIDE.displayName, contentFilter == VaultContentFilter.OUTSIDE) {
                    viewModel.setContentFilter(VaultContentFilter.OUTSIDE)
                }
            }
            VaultViewMode.LIKES -> {
                filter(NostrVaultIcons.Received, VaultLikesFilter.ON_MY_NOTES.displayName, likesFilter == VaultLikesFilter.ON_MY_NOTES) {
                    viewModel.setLikesFilter(VaultLikesFilter.ON_MY_NOTES)
                }
                filter(NostrVaultIcons.Given, VaultLikesFilter.MY_LIKES.displayName, likesFilter == VaultLikesFilter.MY_LIKES) {
                    viewModel.setLikesFilter(VaultLikesFilter.MY_LIKES)
                }
            }
            VaultViewMode.ZAPS -> {
                filter(NostrVaultIcons.Received, VaultZapsFilter.ON_MY_NOTES.displayName, zapsFilter == VaultZapsFilter.ON_MY_NOTES) {
                    viewModel.setZapsFilter(VaultZapsFilter.ON_MY_NOTES)
                }
                filter(NostrVaultIcons.Given, VaultZapsFilter.MY_ZAPS.displayName, zapsFilter == VaultZapsFilter.MY_ZAPS) {
                    viewModel.setZapsFilter(VaultZapsFilter.MY_ZAPS)
                }
            }
            VaultViewMode.FOLLOWERS -> {
                filter(NostrVaultIcons.Discover, VaultFollowersFilter.NEW.displayName, followersFilter == VaultFollowersFilter.NEW) {
                    viewModel.setFollowersFilter(VaultFollowersFilter.NEW)
                }
                filter(NostrVaultIcons.Groups, VaultFollowersFilter.ALL.displayName, followersFilter == VaultFollowersFilter.ALL) {
                    viewModel.setFollowersFilter(VaultFollowersFilter.ALL)
                }
            }
        }
    }
}

/**
 * Lays out the first of [variants] whose natural width fits, else the last —
 * SwiftUI's `ViewThatFits(in: .horizontal)`.
 */
@Composable
private fun FirstThatFits(vararg variants: @Composable () -> Unit) {
    androidx.compose.ui.layout.SubcomposeLayout { constraints ->
        val loose = constraints.copy(minWidth = 0, maxWidth = androidx.compose.ui.unit.Constraints.Infinity)
        var chosen: List<androidx.compose.ui.layout.Placeable> = emptyList()
        for ((index, variant) in variants.withIndex()) {
            chosen = subcompose(index, variant).map { it.measure(loose) }
            if ((chosen.maxOfOrNull { it.width } ?: 0) <= constraints.maxWidth) break
        }
        val width = (chosen.maxOfOrNull { it.width } ?: 0).coerceAtMost(constraints.maxWidth)
        val height = chosen.maxOfOrNull { it.height } ?: 0
        layout(width, height) {
            chosen.forEach { it.placeRelative(0, 0) }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════
// DashboardScreen composable
// ═══════════════════════════════════════════════════════════════════

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DashboardScreen(
    onNavigate: (Screen) -> Unit,
    onNoteClick: (String) -> Unit,
    /** Where a quoted long-form post opens; the note screen shows Markdown source. */
    onArticleClick: (String) -> Unit,
    onProfileClick: (String) -> Unit,
    logStore: com.nostrvault.relay.LogStore,
    feedService: com.nostrvault.service.FeedService,
    viewModel: DashboardViewModel = hiltViewModel(),
) {
    // Stats
    val totalEvents by viewModel.totalEvents.collectAsState()
    val storageUsed by viewModel.storageUsed.collectAsState()
    val noteCount by viewModel.noteCount.collectAsState()
    val dmCount by viewModel.dmCount.collectAsState()
    val mediaCount by viewModel.mediaCount.collectAsState()
    val mediaSize by viewModel.mediaSize.collectAsState()
    val statsLoading by viewModel.statsLoading.collectAsState()

    // Mode & filters
    val viewMode by viewModel.viewMode.collectAsState()
    // In Zaps Only mode the Likes tab is hidden — route a stuck selection back to Notes.
    val zapsOnly = LocalZapsOnlyMode.current
    LaunchedEffect(zapsOnly, viewMode) {
        if (zapsOnly && viewMode == VaultViewMode.LIKES) {
            viewModel.setViewMode(VaultViewMode.NOTES)
        }
    }
    val contentFilter by viewModel.contentFilter.collectAsState()
    val likesFilter by viewModel.likesFilter.collectAsState()
    val zapsFilter by viewModel.zapsFilter.collectAsState()
    val followersFilter by viewModel.followersFilter.collectAsState()
    val followerSnapshot by viewModel.followerSnapshot.collectAsState()
    val hasNewFollowers by viewModel.hasNewFollowers.collectAsState()

    // Re-read the follower ledger every minute while this tab is on screen and
    // the app is in front — feeds both the Followers list and its red dot.
    val lifecycleOwner = androidx.lifecycle.compose.LocalLifecycleOwner.current
    LaunchedEffect(lifecycleOwner) {
        lifecycleOwner.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            viewModel.pollFollowers()
        }
    }

    // Display data
    val displayNotes by viewModel.displayNotes.collectAsState()
    val displayLikedNotes by viewModel.displayLikedNotes.collectAsState()
    val displayZappedNotes by viewModel.displayZappedNotes.collectAsState()

    // Quoted events for the cards below. This tab never asked for them at all,
    // so a quote here was dropped twice over: never fetched, and never drawn.
    val quotedNotes by feedService.quotedNotes.collectAsState()
    LaunchedEffect(displayNotes, displayLikedNotes, displayZappedNotes) {
        val ids = (displayNotes + displayLikedNotes + displayZappedNotes)
            .flatMap { it.quotedEventIds }
            .distinct()
        if (ids.isNotEmpty()) feedService.fetchMissingQuotedNotes(ids)
    }
    LaunchedEffect(displayNotes, displayLikedNotes, displayZappedNotes, quotedNotes) {
        val ids = (displayNotes + displayLikedNotes + displayZappedNotes)
            .flatMap { it.quotedEventIds }
            .distinct()
        if (ids.isNotEmpty()) feedService.fetchMissingQuotedProfiles(ids)
    }
    val reactionMap by viewModel.reactionMap.collectAsState()
    val zapMap by viewModel.zapMap.collectAsState()
    val repostMap by viewModel.repostMap.collectAsState()
    val quoteMap by viewModel.quoteMap.collectAsState()
    val notesHasLoadedOnce by viewModel.notesHasLoadedOnce.collectAsState()
    val likesHasLoadedOnce by viewModel.likesHasLoadedOnce.collectAsState()
    val zapsHasLoadedOnce by viewModel.zapsHasLoadedOnce.collectAsState()
    val walletGivenLoading by viewModel.walletGivenLoading.collectAsState()

    // Connection / loading
    val isRefreshing by viewModel.isRefreshing.collectAsState()
    val isLoadingMore by viewModel.isLoadingMore.collectAsState()
    val connectionColor by viewModel.connectionColor.collectAsState()
    val allProfiles by viewModel.profiles.collectAsState()
    val listState = rememberLazyListState()
    val context = LocalContext.current
    val colors = LocalNostrVaultColors.current

    // A tapped notification parks its event in RelayFocus (see NavGraph). Pick
    // the list that holds it, wait for it to load, scroll it to the middle and
    // outline it for 3 s — iOS consumeRelayFocus. If it never shows (older
    // than the loaded page), open the post instead, so a tap always lands.
    var focusedEventId by remember { mutableStateOf<String?>(null) }
    val currentZapsOnly by rememberUpdatedState(zapsOnly)
    val currentOnNoteClick by rememberUpdatedState(onNoteClick)
    LaunchedEffect(Unit) {
        RelayFocus.pending.filterNotNull().collectLatest {
            val request = RelayFocus.consume() ?: return@collectLatest
            focusedEventId = null
            viewModel.applyRelayFocusView(request, currentZapsOnly)
            if (request.type == NotificationTarget.FOLLOWERS) return@collectLatest
            // The feed dashboard opens a list, not a post: nothing to find.
            if (request.eventId.isEmpty()) return@collectLatest
            // The event can still be arriving from the relay and the lists
            // rebuild on a debounce, so look for up to ~10 s.
            repeat(40) {
                val id = viewModel.focusCandidates(request).firstOrNull { candidate ->
                    focusShownNotes(viewModel).any { it.id == candidate }
                }
                if (id != null) {
                    delay(150) // let the list lay the row out
                    val index = focusShownNotes(viewModel).indexOfFirst { it.id == id }
                    if (index >= 0) {
                        listState.animateScrollToItem(index)
                        val layout = listState.layoutInfo
                        layout.visibleItemsInfo.firstOrNull { it.key == id }?.let { item ->
                            val center = (layout.viewportStartOffset + layout.viewportEndOffset) / 2
                            listState.animateScrollBy((item.offset + item.size / 2 - center).toFloat())
                        }
                        focusedEventId = id
                        delay(3_000)
                        focusedEventId = null
                        return@collectLatest
                    }
                }
                delay(250)
            }
            viewModel.focusFallbackNoteId(request)?.let { currentOnNoteClick(it) }
        }
    }

    // Dashboard bottom sheet state
    var showDashboardSheet by remember { mutableStateOf(false) }
    val dashboardSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    // Zap sheet state
    var zapNoteId by remember { mutableStateOf<String?>(null) }
    val zapSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    // Trigger load-more when near bottom
    val shouldLoadMore by remember {
        derivedStateOf {
            val lastVisible = listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0
            val total = listState.layoutInfo.totalItemsCount
            val result = lastVisible >= total - 5
            result
        }
    }
    LaunchedEffect(shouldLoadMore, isRefreshing) {
        android.util.Log.d("DashboardScreen", "shouldLoadMore=$shouldLoadMore, isRefreshing=$isRefreshing, items=${listState.layoutInfo.totalItemsCount}")
        if (shouldLoadMore && !isRefreshing) {
            android.util.Log.d("DashboardScreen", "Triggering loadMore()")
            viewModel.loadMore()
        }
    }

    // Reconnect to local relay when the app returns to the foreground
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        viewModel.onResume()
    }
    // Save snapshot when the app goes to background so next cold launch is instant
    LifecycleEventEffect(Lifecycle.Event.ON_STOP) {
        viewModel.persistSnapshot()
    }

    // Log polling is owned by RelayForegroundService for the relay's whole lifetime
    // (so the relay-activity red dot is detected continuously, not just while this
    // screen is visible). The console just observes logStore.logs below.

    // Connection dot color for FAB
    val dotColor = when (connectionColor) {
        "green" -> SuccessGreen
        "yellow", "orange" -> ZapOrange
        "red" -> ErrorRed
        else -> SecondaryText
    }

    // Where the list is relative to its top: the chrome always shows near it.
    ScrollCondenseEffect(
        scrollKey = listState,
        firstVisibleItemIndex = { listState.firstVisibleItemIndex },
        firstVisibleItemScrollOffset = { listState.firstVisibleItemScrollOffset },
    )

    // Tapping the Relay tab again goes to the top of the list (iOS #275).
    LaunchedEffect(Unit) {
        TabReselect.of(Screen.Dashboard).collect { listState.animateScrollToItem(0) }
    }

    // Condensed-bar relay antenna opens the dashboard stats sheet (iOS parity).
    LaunchedEffect(Unit) {
        feedService.relayDashboardRequest.collect {
            viewModel.loadStats()
            showDashboardSheet = true
        }
    }

    GlassScaffold(
        toolbar = {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .statusBarsPadding()
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            ) {
                // Leading pill: mode switcher (Notes / Likes / Zaps / Followers)
                GlassPill(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    IconFilterButton(
                        icon = NostrVaultIcons.Document,
                        contentDescription = "Notes",
                        isSelected = viewMode == VaultViewMode.NOTES,
                        onClick = { viewModel.setViewMode(VaultViewMode.NOTES) },
                    )
                    if (!LocalZapsOnlyMode.current) {
                        IconFilterButton(
                            icon = NostrVaultIcons.HeartFilled,
                            contentDescription = "Likes",
                            isSelected = viewMode == VaultViewMode.LIKES,
                            onClick = { viewModel.setViewMode(VaultViewMode.LIKES) },
                        )
                    }
                    IconFilterButton(
                        icon = NostrVaultIcons.Zap,
                        contentDescription = "Zaps",
                        isSelected = viewMode == VaultViewMode.ZAPS,
                        onClick = { viewModel.setViewMode(VaultViewMode.ZAPS) },
                    )
                    IconFilterButton(
                        icon = NostrVaultIcons.People,
                        contentDescription = if (hasNewFollowers) "Followers, new followers" else "Followers",
                        isSelected = viewMode == VaultViewMode.FOLLOWERS,
                        onClick = { viewModel.setViewMode(VaultViewMode.FOLLOWERS) },
                        showDot = hasNewFollowers,
                    )
                }

                Spacer(Modifier.width(8.dp))

                // Trailing pill: the current mode's filters. Each icon means one
                // thing in every mode (tray in = others gave you, tray out = you
                // gave), and the selected one says its word. They never collapse
                // into a menu: when the bar is tight the word goes, not the icons.
                Box(Modifier.weight(1f), contentAlignment = Alignment.CenterEnd) {
                    FirstThatFits(
                        { RelayFilterPill(viewMode, contentFilter, likesFilter, zapsFilter, followersFilter, viewModel, labelled = true) },
                        { RelayFilterPill(viewMode, contentFilter, likesFilter, zapsFilter, followersFilter, viewModel, labelled = false) },
                    )
                }
            }
        },
        floatingActionButton = {
            // The FAB folds with the bars, following the finger.
            val folded by rememberChromeFolded()
            Box(Modifier.chromeFab().blockedWhen(folded)) {
                Surface(
                    onClick = {
                        viewModel.loadStats()
                        showDashboardSheet = true
                    },
                    modifier = Modifier.floatingRowButton(),
                    color = dotColor,
                    shape = CircleShape,
                    shadowElevation = 8.dp,
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .height(FloatingButtonRow.buttonHeight)
                            .padding(horizontal = 18.dp),
                    ) {
                        Icon(
                            imageVector = NostrVaultIcons.Relay,
                            contentDescription = null,
                            tint = PrimaryText,
                            modifier = Modifier.size(18.dp),
                        )
                        Spacer(Modifier.width(6.dp))
                        Text(
                            text = "Relay",
                            color = PrimaryText,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Bold,
                        )
                    }
                }
            }
        },
    ) { padding ->
        // Whatever the visible notes quote. The relay tab strips the nostr:
        // reference out of the body text and drew nothing in its place, so a
        // quoted note or article left no trace here at all — the feed and
        // thread screens already resolve theirs this way.
        val visibleNotes = when (viewMode) {
            VaultViewMode.NOTES -> displayNotes
            VaultViewMode.LIKES -> displayLikedNotes
            VaultViewMode.ZAPS -> displayZappedNotes
            VaultViewMode.FOLLOWERS -> emptyList()
        }
        val quotedIds = remember(visibleNotes) {
            visibleNotes.flatMap { it.quotedEventIds }.distinct()
        }
        LaunchedEffect(quotedIds) {
            if (quotedIds.isNotEmpty()) {
                feedService.fetchMissingQuotedNotes(quotedIds)
                feedService.fetchMissingQuotedProfiles(quotedIds)
            }
        }
        val resolvedQuotes by feedService.parentNotesCache.collectAsState()
        val quotedNotes = remember(quotedIds, resolvedQuotes) {
            quotedIds.mapNotNull { id -> feedService.quotedNoteFor(id)?.let { id to it } }.toMap()
        }

        // Long-press Report Post / Block User on a row (iOS NoteRow). Reporting
        // also blocks the author, matching the feed, NoteDetail, and iOS.
        val blockAuthor: (String) -> Unit = { pubkey -> feedService.blockUser(pubkey) }
        val reportNote: (FeedNote, String, String) -> Unit = { note, reason, description ->
            viewModel.reportNote(note.id, note.pubkey, reason, description)
            feedService.blockUser(note.pubkey)
        }

        PullToRefreshBox(
            isRefreshing = isRefreshing,
            onRefresh = viewModel::loadLocalRelayNotes,
            modifier = Modifier.fillMaxSize(),
        ) {
            when (viewMode) {
                VaultViewMode.NOTES -> NotesContent(
                    notes = displayNotes,
                    quotedNotes = quotedNotes,
                    reactionMap = reactionMap,
                    zapMap = zapMap,
                    repostMap = repostMap,
                    quoteMap = quoteMap,
                    isRefreshing = isRefreshing,
                    hasLoadedOnce = notesHasLoadedOnce,
                    isLoadingMore = isLoadingMore,
                    listState = listState,
                    allProfiles = allProfiles,
                    padding = padding,
                    viewModel = viewModel,
                    onNoteClick = onNoteClick,
                    onArticleClick = onArticleClick,
                    onProfileClick = onProfileClick,
                    focusedEventId = focusedEventId,
                    onReportNote = reportNote,
                    onBlockAuthor = blockAuthor,
                )
                VaultViewMode.LIKES -> LikesContent(
                    notes = displayLikedNotes,
                    quotedNotes = quotedNotes,
                    reactionMap = reactionMap,
                    hasLoadedOnce = likesHasLoadedOnce,
                    isRefreshing = isRefreshing,
                    likesFilter = likesFilter,
                    listState = listState,
                    allProfiles = allProfiles,
                    padding = padding,
                    viewModel = viewModel,
                    onNoteClick = onNoteClick,
                    onArticleClick = onArticleClick,
                    onProfileClick = onProfileClick,
                    focusedEventId = focusedEventId,
                    onReportNote = reportNote,
                    onBlockAuthor = blockAuthor,
                )
                VaultViewMode.ZAPS -> ZapsContent(
                    notes = displayZappedNotes,
                    quotedNotes = quotedNotes,
                    zapMap = zapMap,
                    hasLoadedOnce = zapsHasLoadedOnce,
                    isRefreshing = isRefreshing,
                    zapsFilter = zapsFilter,
                    walletGivenLoading = walletGivenLoading,
                    listState = listState,
                    allProfiles = allProfiles,
                    padding = padding,
                    viewModel = viewModel,
                    onNoteClick = onNoteClick,
                    onArticleClick = onArticleClick,
                    onProfileClick = onProfileClick,
                    focusedEventId = focusedEventId,
                    onReportNote = reportNote,
                    onBlockAuthor = blockAuthor,
                )
                VaultViewMode.FOLLOWERS -> FollowersContent(
                    snapshot = followerSnapshot,
                    filter = followersFilter,
                    listState = listState,
                    allProfiles = allProfiles,
                    padding = padding,
                    onProfileClick = onProfileClick,
                )
            }
        }
    }

    // Dashboard stats bottom sheet
    if (showDashboardSheet) {
        ModalBottomSheet(
            onDismissRequest = { showDashboardSheet = false },
            sheetState = dashboardSheetState,
            containerColor = WindowBackground,
            dragHandle = {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.padding(top = 12.dp, bottom = 4.dp),
                ) {
                    Box(
                        modifier = Modifier
                            .size(width = 36.dp, height = 4.dp)
                            .background(
                                SecondaryText.copy(alpha = 0.4f),
                                RoundedCornerShape(2.dp),
                            ),
                    )
                }
            },
        ) {
            val currentRelayStatus by RelayForegroundService.relayStatus.collectAsState()
            val currentIsLocked by RelayForegroundService.isLocked.collectAsState()
            val currentIsPortConflict by RelayForegroundService.isPortConflict.collectAsState()
            val currentLogs by logStore.logs.collectAsState()
            val currentConfig by viewModel.configStore.config.collectAsState()
            val context = LocalContext.current

            DashboardSheetContent(
                totalEvents = totalEvents,
                storageUsed = storageUsed,
                noteCount = noteCount,
                dmCount = dmCount,
                mediaCount = mediaCount,
                mediaSize = mediaSize,
                isLoading = statsLoading,
                relayStatus = currentRelayStatus,
                relayAddress = currentConfig.nostrURL,
                isExternalRelay = currentConfig.useExternalRelay,
                isLocked = currentIsLocked,
                isPortConflict = currentIsPortConflict,
                onRefresh = viewModel::loadStats,
                onBlossomClick = {
                    showDashboardSheet = false
                    onNavigate(Screen.BlossomDashboard)
                },
                onStartRelay = { RelayForegroundService.start(context) },
                onStopRelay = { RelayForegroundService.stop(context) },
                onRestartRelay = {
                    RelayForegroundService.stop(context)
                    android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                        RelayForegroundService.start(context)
                    }, 1500)
                },
                onForceRestart = { RelayForegroundService.forceRestart(context) },
                onClearLocks = { RelayForegroundService.clearLocksPublic(context) },
                logs = currentLogs,
                onViewAllLogs = {
                    showDashboardSheet = false
                    onNavigate(Screen.RelayActivity)
                },
                statsService = viewModel.statsService,
                ownerPubkey = viewModel.nostrService.ownerHexPubkey,
                cacheDir = currentConfig.appSupportDir?.let { "$it/media_cache" },
                cacheTTLDays = currentConfig.cacheTTLDays,
                isImporting = viewModel.isImporting.collectAsState().value,
                importProgress = viewModel.importProgress.collectAsState().value,
                importStatusMessage = viewModel.importStatusMessage.collectAsState().value,
                importCompleted = viewModel.importCompleted.collectAsState().value,
                isExportingJsonl = viewModel.isExportingJsonl.collectAsState().value,
                isExportingMedia = viewModel.isExportingMedia.collectAsState().value,
                isImportingBlossom = viewModel.blossomMirrorRun.collectAsState().value.running,
                onImportNotes = { viewModel.importNotes(context) },
                onImportBlossom = viewModel::importBlossom,
                onExportJsonl = { viewModel.exportJsonl(context) },
                onExportMedia = { viewModel.exportMedia(context) },
                onDismissImport = viewModel::dismissImport,
            )
        }
    }

    // Zap sheet
    if (zapNoteId != null) {
        CustomZapSheet(
            sheetState = zapSheetState,
            defaultAmount = viewModel.configStore.config.value.defaultZapAmount,
            onDismiss = { zapNoteId = null },
            onZap = { _ -> zapNoteId = null },
        )
    }
}

// ═══════════════════════════════════════════════════════════════════
// Notes content
// ═══════════════════════════════════════════════════════════════════

@Composable
private fun NotesContent(
    notes: List<FeedNote>,
    quotedNotes: Map<String, FeedNote>,
    reactionMap: Map<String, List<Pair<String, String>>>,
    zapMap: Map<String, List<Pair<String, Long>>>,
    repostMap: Map<String, List<String>>,
    quoteMap: Map<String, List<String>>,
    isRefreshing: Boolean,
    hasLoadedOnce: Boolean,
    isLoadingMore: Boolean,
    listState: androidx.compose.foundation.lazy.LazyListState,
    allProfiles: Map<String, FeedProfile>,
    padding: PaddingValues,
    viewModel: DashboardViewModel,
    onNoteClick: (String) -> Unit,
    onArticleClick: (String) -> Unit,
    onProfileClick: (String) -> Unit,
    /** The row a tapped notification landed on, outlined briefly. */
    focusedEventId: String? = null,
    onReportNote: (FeedNote, String, String) -> Unit,
    onBlockAuthor: (String) -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val latestReactionDates by viewModel.latestReactionDates.collectAsState()

    if (notes.isEmpty() && (isRefreshing || !hasLoadedOnce)) {
        SkeletonFeed(count = 5)
    } else if (notes.isEmpty()) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .fillMaxSize()
                .padding(top = padding.calculateTopPadding()),
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(
                    imageVector = NostrVaultIcons.Relay,
                    contentDescription = null,
                    tint = TertiaryText,
                    modifier = Modifier.size(48.dp),
                )
                Spacer(Modifier.height(12.dp))
                Text(
                    text = "No notes found",
                    color = SecondaryText,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Bold,
                )
                Text(
                    text = "Try changing your filter settings",
                    color = TertiaryText,
                    fontSize = 13.sp,
                )
            }
        }
    } else {
        LazyColumn(
            state = listState,
            contentPadding = PaddingValues(
                top = padding.calculateTopPadding(),
                bottom = padding.calculateBottomPadding() + 88.dp,
            ),
            modifier = Modifier.fillMaxSize(),
        ) {
            items(items = notes, key = { it.id }) { note ->
                val noteType = when {
                    note.pubkey == viewModel.currentUserPubkey() -> VaultNoteType.MINE
                    viewModel.isWhitelisted(note.pubkey) -> VaultNoteType.WHITELISTED
                    else -> VaultNoteType.TAGGED
                }
                VaultNoteCard(
                    note = note,
                    quotedNotes = quotedNotes,
                    profile = viewModel.profileFor(note.pubkey),
                    profiles = allProfiles,
                    reactors = reactionMap[note.id] ?: emptyList(),
                    latestReactionDate = latestReactionDates[note.id]?.let { java.util.Date(it * 1000) },
                    reposterPubkeys = repostMap[note.id] ?: emptyList(),
                    quoterPubkeys = quoteMap[note.id] ?: emptyList(),
                    zappers = zapMap[note.id] ?: emptyList(),
                    noteType = noteType,
                    layoutMode = VaultNoteLayoutMode.EXPANDED,
                    onNoteClick = onNoteClick,
                    onArticleClick = onArticleClick,
                    onProfileClick = onProfileClick,
                    onReport = { reason, description -> onReportNote(note, reason, description) },
                    onBlock = { onBlockAuthor(note.pubkey) },
                    modifier = Modifier
                        .padding(horizontal = 16.dp, vertical = 6.dp)
                        .relayFocusOutline(note.id == focusedEventId),
                )
            }

            if (isLoadingMore) {
                item {
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(16.dp),
                    ) {
                        CircularProgressIndicator(
                            color = colors.primary,
                            modifier = Modifier.size(24.dp),
                        )
                    }
                }
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════
// Likes content
// ═══════════════════════════════════════════════════════════════════

@Composable
private fun LikesContent(
    notes: List<FeedNote>,
    quotedNotes: Map<String, FeedNote>,
    reactionMap: Map<String, List<Pair<String, String>>>,
    hasLoadedOnce: Boolean,
    isRefreshing: Boolean,
    likesFilter: VaultLikesFilter,
    listState: androidx.compose.foundation.lazy.LazyListState,
    allProfiles: Map<String, FeedProfile>,
    padding: PaddingValues,
    viewModel: DashboardViewModel,
    onNoteClick: (String) -> Unit,
    onArticleClick: (String) -> Unit,
    onProfileClick: (String) -> Unit,
    /** The row a tapped notification landed on, outlined briefly. */
    focusedEventId: String? = null,
    onReportNote: (FeedNote, String, String) -> Unit,
    onBlockAuthor: (String) -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val latestReactionDates by viewModel.latestReactionDates.collectAsState()

    if (notes.isEmpty() && (isRefreshing || !hasLoadedOnce)) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .fillMaxSize()
                .padding(top = padding.calculateTopPadding()),
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                CircularProgressIndicator(
                    color = colors.primary,
                    modifier = Modifier.size(32.dp),
                )
                Spacer(Modifier.height(16.dp))
                Text(
                    text = "Loading likes...",
                    color = PrimaryText,
                    fontSize = 18.sp,
                    fontWeight = FontWeight.Bold,
                )
                Text(
                    text = "This may take a moment",
                    color = TertiaryText,
                    fontSize = 12.sp,
                )
            }
        }
    } else if (notes.isEmpty()) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .fillMaxSize()
                .padding(top = padding.calculateTopPadding()),
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(
                    imageVector = if (likesFilter != VaultLikesFilter.MY_LIKES) NostrVaultIcons.HeartFilled else NostrVaultIcons.Heart,
                    contentDescription = null,
                    tint = LikeRed,
                    modifier = Modifier.size(48.dp),
                )
                Spacer(Modifier.height(12.dp))
                Text(
                    text = if (likesFilter != VaultLikesFilter.MY_LIKES) "No reactions yet" else "No liked posts",
                    color = SecondaryText,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Bold,
                )
                Text(
                    text = if (likesFilter != VaultLikesFilter.MY_LIKES) "Reactions on these notes will appear here" else "Posts you've liked will appear here",
                    color = TertiaryText,
                    fontSize = 13.sp,
                )
            }
        }
    } else {
        LazyColumn(
            state = listState,
            contentPadding = PaddingValues(
                top = padding.calculateTopPadding(),
                bottom = padding.calculateBottomPadding() + 88.dp,
            ),
            modifier = Modifier.fillMaxSize(),
        ) {
            items(items = notes, key = { it.id }) { note ->
                val noteType = when {
                    note.pubkey == viewModel.currentUserPubkey() -> VaultNoteType.MINE
                    viewModel.isWhitelisted(note.pubkey) -> VaultNoteType.WHITELISTED
                    else -> VaultNoteType.TAGGED
                }
                VaultNoteCard(
                    note = note,
                    quotedNotes = quotedNotes,
                    profile = viewModel.profileFor(note.pubkey),
                    profiles = allProfiles,
                    reactors = reactionMap[note.id] ?: emptyList(),
                    latestReactionDate = latestReactionDates[note.id]?.let { java.util.Date(it * 1000) },
                    noteType = noteType,
                    layoutMode = VaultNoteLayoutMode.EXPANDED,
                    onNoteClick = onNoteClick,
                    onArticleClick = onArticleClick,
                    onProfileClick = onProfileClick,
                    onReport = { reason, description -> onReportNote(note, reason, description) },
                    onBlock = { onBlockAuthor(note.pubkey) },
                    modifier = Modifier
                        .padding(horizontal = 16.dp, vertical = 6.dp)
                        .relayFocusOutline(note.id == focusedEventId),
                )
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════
// Zaps content
// ═══════════════════════════════════════════════════════════════════

@Composable
private fun ZapsContent(
    notes: List<FeedNote>,
    quotedNotes: Map<String, FeedNote>,
    zapMap: Map<String, List<Pair<String, Long>>>,
    hasLoadedOnce: Boolean,
    isRefreshing: Boolean,
    zapsFilter: VaultZapsFilter,
    /** The wallet's history is still being read for Given (one NWC call can take 15s). */
    walletGivenLoading: Boolean,
    listState: androidx.compose.foundation.lazy.LazyListState,
    allProfiles: Map<String, FeedProfile>,
    padding: PaddingValues,
    viewModel: DashboardViewModel,
    onNoteClick: (String) -> Unit,
    onArticleClick: (String) -> Unit,
    onProfileClick: (String) -> Unit,
    /** The row a tapped notification landed on, outlined briefly. */
    focusedEventId: String? = null,
    onReportNote: (FeedNote, String, String) -> Unit,
    onBlockAuthor: (String) -> Unit,
) {
    val colors = LocalNostrVaultColors.current

    // Settle-driven loading: hasLoadedOnce is set either when zaps arrive or by a
    // bounded ~6s settle (armZapsSettle), so the spinner never hangs forever when
    // there are simply no zaps. Don't gate on isRefreshing here. The wallet's
    // history can outlast that settle, so Given keeps spinning while it is read.
    if (notes.isEmpty() && (!hasLoadedOnce || (zapsFilter == VaultZapsFilter.MY_ZAPS && walletGivenLoading))) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .fillMaxSize()
                .padding(top = padding.calculateTopPadding()),
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                CircularProgressIndicator(
                    color = colors.primary,
                    modifier = Modifier.size(32.dp),
                )
                Spacer(Modifier.height(16.dp))
                Text(
                    text = "Loading zaps...",
                    color = PrimaryText,
                    fontSize = 18.sp,
                    fontWeight = FontWeight.Bold,
                )
                Text(
                    text = "This may take a moment",
                    color = TertiaryText,
                    fontSize = 12.sp,
                )
            }
        }
    } else if (notes.isEmpty()) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .fillMaxSize()
                .padding(top = padding.calculateTopPadding()),
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(
                    imageVector = NostrVaultIcons.Zap,
                    contentDescription = null,
                    tint = ZapOrange,
                    modifier = Modifier.size(48.dp),
                )
                Spacer(Modifier.height(12.dp))
                Text(
                    text = if (zapsFilter != VaultZapsFilter.MY_ZAPS) "No zaps yet" else "No zapped posts",
                    color = SecondaryText,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Bold,
                )
                Text(
                    text = if (zapsFilter != VaultZapsFilter.MY_ZAPS) "Zaps on these notes will appear here" else "Posts you've zapped will appear here",
                    color = TertiaryText,
                    fontSize = 13.sp,
                )
            }
        }
    } else {
        LazyColumn(
            state = listState,
            contentPadding = PaddingValues(
                top = padding.calculateTopPadding(),
                bottom = padding.calculateBottomPadding() + 88.dp,
            ),
            modifier = Modifier.fillMaxSize(),
        ) {
            items(items = notes, key = { it.id }) { note ->
                val noteType = when {
                    note.pubkey == viewModel.currentUserPubkey() -> VaultNoteType.MINE
                    viewModel.isWhitelisted(note.pubkey) -> VaultNoteType.WHITELISTED
                    else -> VaultNoteType.TAGGED
                }
                VaultNoteCard(
                    note = note,
                    quotedNotes = quotedNotes,
                    profile = viewModel.profileFor(note.pubkey),
                    profiles = allProfiles,
                    zappers = zapMap[note.id] ?: emptyList(),
                    noteType = noteType,
                    layoutMode = VaultNoteLayoutMode.EXPANDED,
                    onNoteClick = onNoteClick,
                    onArticleClick = onArticleClick,
                    onProfileClick = onProfileClick,
                    onReport = { reason, description -> onReportNote(note, reason, description) },
                    onBlock = { onBlockAuthor(note.pubkey) },
                    modifier = Modifier
                        .padding(horizontal = 16.dp, vertical = 6.dp)
                        .relayFocusOutline(note.id == focusedEventId),
                )
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════
// LikedByRow — shows reactor avatars and "name1, name2 liked"
// ═══════════════════════════════════════════════════════════════════

@Composable
private fun LikedByRow(
    reactors: List<Pair<String, String>>,
    profiles: Map<String, FeedProfile>,
    modifier: Modifier = Modifier,
) {
    val unique = reactors.distinctBy { it.first }.take(5)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier,
    ) {
        Text(
            text = reactionEmojiSummary(reactors.map { it.second }, limit = 3),
            fontSize = 12.sp,
        )
        Spacer(Modifier.width(6.dp))

        // Overlapping avatars
        Box {
            unique.forEachIndexed { index, (pubkey, _) ->
                val profile = profiles[pubkey]
                AsyncImage(
                    model = profile?.pictureURL,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier
                        .padding(start = (index * 16).dp)
                        .size(22.dp)
                        .clip(CircleShape)
                        .border(1.5.dp, SecondaryGroupedBg, CircleShape)
                        .background(SecondaryGroupedBg, CircleShape),
                )
            }
        }
        Spacer(Modifier.width(6.dp))

        // "name1, name2 liked" (or "reacted" when any reaction isn't a plain heart)
        val names = unique.take(3).map { (pubkey, _) ->
            profiles[pubkey]?.bestName ?: "npub\u2026${pubkey.takeLast(4)}"
        }
        val remaining = unique.size - names.size
        val allHearts = reactors.all { reactionDisplayEmoji(it.second) == "\u2764\ufe0f" }
        val text = buildString {
            append(names.joinToString(", "))
            if (remaining > 0) append(" +$remaining more")
            append(if (allHearts) " liked" else " reacted")
        }
        Text(
            text = text,
            color = SecondaryText,
            fontSize = 13.sp,
            fontWeight = FontWeight.Medium,
            maxLines = 1,
        )
    }
}

// ═══════════════════════════════════════════════════════════════════
// ZappedByRow — shows zapper avatars, names, and total sats
// ═══════════════════════════════════════════════════════════════════

@Composable
private fun ZappedByRow(
    zappers: List<Pair<String, Long>>,
    profiles: Map<String, FeedProfile>,
    modifier: Modifier = Modifier,
) {
    val unique = zappers.distinctBy { it.first }.take(5)
    val totalSats = zappers.sumOf { it.second }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier,
    ) {
        Icon(
            imageVector = NostrVaultIcons.Zap,
            contentDescription = null,
            tint = ZapOrange,
            modifier = Modifier.size(11.dp),
        )
        Spacer(Modifier.width(6.dp))

        // Overlapping avatars
        Box {
            unique.forEachIndexed { index, (pubkey, _) ->
                val profile = profiles[pubkey]
                AsyncImage(
                    model = profile?.pictureURL,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier
                        .padding(start = (index * 14).dp)
                        .size(20.dp)
                        .clip(CircleShape)
                        .border(1.5.dp, SecondaryGroupedBg, CircleShape)
                        .background(SecondaryGroupedBg, CircleShape),
                )
            }
        }
        Spacer(Modifier.width(6.dp))

        val names = unique.take(3).map { (pubkey, _) ->
            profiles[pubkey]?.bestName ?: "npub\u2026${pubkey.takeLast(4)}"
        }
        val remaining = unique.size - names.size
        val text = buildString {
            append(names.joinToString(", "))
            if (remaining > 0) append(" +$remaining more")
            append(" zapped")
            if (totalSats > 0) {
                val formatted = NumberFormat.getNumberInstance().format(totalSats)
                append(" \u00B7 $formatted sats")
            }
        }
        Text(
            text = text,
            color = SecondaryText,
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            maxLines = 1,
        )
    }
}

// ═══════════════════════════════════════════════════════════════════
// Dashboard bottom sheet content
// ═══════════════════════════════════════════════════════════════════

@Composable
private fun DashboardSheetContent(
    totalEvents: Int,
    storageUsed: String,
    noteCount: Int,
    dmCount: Int,
    mediaCount: Int,
    mediaSize: String,
    isLoading: Boolean,
    relayStatus: RelayForegroundService.RelayStatus,
    relayAddress: String?,
    isExternalRelay: Boolean,
    isLocked: Boolean,
    isPortConflict: Boolean,
    onRefresh: () -> Unit,
    onBlossomClick: () -> Unit,
    onStartRelay: () -> Unit,
    onStopRelay: () -> Unit,
    onRestartRelay: () -> Unit,
    onForceRestart: () -> Unit,
    onClearLocks: () -> Unit,
    logs: List<com.nostrvault.relay.RelayLogParser.LogEntry>,
    onViewAllLogs: () -> Unit,
    statsService: StatsService,
    ownerPubkey: String,
    cacheDir: String?,
    cacheTTLDays: Int,
    isImporting: Boolean,
    importProgress: Float,
    importStatusMessage: String,
    importCompleted: Boolean,
    isExportingJsonl: Boolean,
    isExportingMedia: Boolean,
    isImportingBlossom: Boolean,
    onImportNotes: () -> Unit,
    onImportBlossom: () -> Unit,
    onExportJsonl: () -> Unit,
    onExportMedia: () -> Unit,
    onDismissImport: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp)
            .padding(bottom = 32.dp),
    ) {
        // Header
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = 16.dp),
        ) {
            Icon(
                imageVector = NostrVaultIcons.Relay,
                contentDescription = null,
                tint = colors.primary,
                modifier = Modifier.size(20.dp),
            )
            Spacer(Modifier.width(8.dp))
            Text(
                text = "Relay Dashboard",
                color = PrimaryText,
                fontSize = 18.sp,
                fontWeight = FontWeight.Bold,
            )
            Spacer(Modifier.weight(1f))

            IconButton(onClick = onRefresh, modifier = Modifier.size(32.dp)) {
                Icon(
                    NostrVaultIcons.Refresh,
                    "Refresh",
                    tint = SecondaryText,
                    modifier = Modifier.size(18.dp),
                )
            }
        }

        // Relay status header
        com.nostrvault.ui.screens.dashboard.RelayStatusHeader(
            relayStatus = relayStatus,
            relayAddress = relayAddress,
            isExternalRelay = isExternalRelay,
            isLocked = isLocked,
            isPortConflict = isPortConflict,
            onStartRelay = onStartRelay,
            onStopRelay = onStopRelay,
            onRestartRelay = onRestartRelay,
            onForceRestart = onForceRestart,
            onClearLocks = onClearLocks,
        )

        Spacer(Modifier.height(12.dp))

        // Compact log console
        if (logs.isNotEmpty()) {
            com.nostrvault.ui.screens.dashboard.CompactLogConsole(
                logs = logs,
                onViewAll = onViewAllLogs,
            )
            Spacer(Modifier.height(12.dp))
        }

        if (isLoading) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(32.dp),
            ) {
                CircularProgressIndicator(color = colors.primary)
            }
        } else {
            // Breakdown sheet state
            var showEventBreakdown by remember { mutableStateOf(false) }
            var showStorageBreakdown by remember { mutableStateOf(false) }
            var showBlossomBreakdown by remember { mutableStateOf(false) }
            var showCacheBreakdown by remember { mutableStateOf(false) }

            // Stats grid -- clickable cards that open breakdown sheets
            Row(
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                StatsCard(
                    title = "Total Events",
                    value = totalEvents.toString(),
                    icon = NostrVaultIcons.AppIcon,
                    modifier = Modifier.weight(1f),
                    onClick = { showEventBreakdown = true },
                )
                StatsCard(
                    title = "Storage",
                    value = storageUsed,
                    icon = NostrVaultIcons.Storage,
                    modifier = Modifier.weight(1f),
                    onClick = { showStorageBreakdown = true },
                )
            }

            Spacer(Modifier.height(12.dp))

            Row(
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                StatsCard(
                    title = "Notes",
                    value = noteCount.toString(),
                    icon = NostrVaultIcons.Feed,
                    modifier = Modifier.weight(1f),
                )
                StatsCard(
                    title = "DMs",
                    value = dmCount.toString(),
                    icon = NostrVaultIcons.DMs,
                    modifier = Modifier.weight(1f),
                )
            }

            Spacer(Modifier.height(12.dp))

            Row(
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                StatsCard(
                    title = "Blossom Media",
                    value = mediaCount.toString(),
                    icon = NostrVaultIcons.Blossom,
                    modifier = Modifier.weight(1f),
                    onClick = { showBlossomBreakdown = true },
                )
                StatsCard(
                    title = "Media Cache",
                    value = mediaSize,
                    icon = NostrVaultIcons.Media,
                    modifier = Modifier.weight(1f),
                    onClick = { showCacheBreakdown = true },
                )
            }

            // Breakdown sheets
            if (showEventBreakdown) {
                com.nostrvault.ui.screens.dashboard.EventKindBreakdownSheet(
                    statsService = statsService,
                    onDismiss = { showEventBreakdown = false },
                )
            }
            if (showStorageBreakdown) {
                com.nostrvault.ui.screens.dashboard.StorageBreakdownSheet(
                    statsService = statsService,
                    onDismiss = { showStorageBreakdown = false },
                )
            }
            if (showBlossomBreakdown) {
                com.nostrvault.ui.screens.dashboard.BlossomBreakdownSheet(
                    statsService = statsService,
                    ownerPubkey = ownerPubkey,
                    onDismiss = { showBlossomBreakdown = false },
                )
            }
            if (showCacheBreakdown) {
                com.nostrvault.ui.screens.dashboard.CacheBreakdownSheet(
                    statsService = statsService,
                    cacheDir = cacheDir,
                    cacheTTLDays = cacheTTLDays,
                    onDismiss = { showCacheBreakdown = false },
                )
            }

            Spacer(Modifier.height(24.dp))

            // Import/Export actions
            com.nostrvault.ui.screens.dashboard.ImportExportSection(
                isImporting = isImporting,
                importProgress = importProgress,
                importStatusMessage = importStatusMessage,
                importCompleted = importCompleted,
                isExportingJsonl = isExportingJsonl,
                isExportingMedia = isExportingMedia,
                isImportingBlossom = isImportingBlossom,
                onImportNotes = onImportNotes,
                onImportBlossom = onImportBlossom,
                onExportJsonl = onExportJsonl,
                onExportMedia = onExportMedia,
                onDismissImport = onDismissImport,
            )

            Spacer(Modifier.height(24.dp))

            // Blossom link
            Surface(
                color = SecondaryGroupedBg,
                shape = RoundedCornerShape(12.dp),
                onClick = onBlossomClick,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.padding(16.dp),
                ) {
                    Icon(
                        imageVector = NostrVaultIcons.Media,
                        contentDescription = null,
                        tint = colors.primary,
                        modifier = Modifier.size(24.dp),
                    )
                    Spacer(Modifier.width(12.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text("Blossom Media", color = PrimaryText, fontWeight = FontWeight.SemiBold)
                        Text("Manage media servers and mirrors", color = SecondaryText, fontSize = 13.sp)
                    }
                    Icon(NostrVaultIcons.Navigate, null, tint = TertiaryText, modifier = Modifier.size(16.dp))
                }
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════
// Stats card
// ═══════════════════════════════════════════════════════════════════

@Composable
private fun StatsCard(
    title: String,
    value: String,
    icon: ImageVector,
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null,
) {
    val colors = LocalNostrVaultColors.current

    Surface(
        color = SecondaryGroupedBg,
        shape = RoundedCornerShape(12.dp),
        onClick = onClick ?: {},
        enabled = onClick != null,
        modifier = modifier,
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = colors.primary,
                modifier = Modifier.size(20.dp),
            )
            Spacer(Modifier.height(8.dp))
            Text(
                text = value,
                color = PrimaryText,
                fontSize = 22.sp,
                fontWeight = FontWeight.Bold,
            )
            Text(
                text = title,
                color = SecondaryText,
                fontSize = 12.sp,
            )
        }
    }
}

@kotlinx.serialization.Serializable
data class DiskVaultSnapshot(
    val events: List<com.nostrvault.service.NostrEvent>,
    val savedAt: Long,
)

// ═══════════════════════════════════════════════════════════════════
// Followers content (relay follower ledger, iOS #136)
// ═══════════════════════════════════════════════════════════════════

@Composable
private fun FollowersContent(
    snapshot: FollowerSnapshot?,
    filter: VaultFollowersFilter,
    listState: androidx.compose.foundation.lazy.LazyListState,
    allProfiles: Map<String, FeedProfile>,
    padding: PaddingValues,
    onProfileClick: (String) -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    if (snapshot == null) {
        val relayStatus by RelayForegroundService.relayStatus.collectAsState()
        val running = relayStatus == RelayForegroundService.RelayStatus.RUNNING
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .fillMaxSize()
                .padding(top = padding.calculateTopPadding()),
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                CircularProgressIndicator(color = colors.primary, modifier = Modifier.size(32.dp))
                Spacer(Modifier.height(16.dp))
                Text(
                    text = if (running) "Loading followers..." else "Followers show once the relay is running",
                    color = SecondaryText,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }
        return
    }
    val entries = remember(snapshot, filter) { snapshot.entries(filter) }
    LazyColumn(
        state = listState,
        contentPadding = PaddingValues(
            top = padding.calculateTopPadding(),
            bottom = padding.calculateBottomPadding() + 88.dp,
        ),
        modifier = Modifier.fillMaxSize(),
    ) {
        item(key = "followers-summary") {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 12.dp),
            ) {
                Icon(
                    imageVector = NostrVaultIcons.People,
                    contentDescription = null,
                    tint = colors.primary,
                    modifier = Modifier.size(18.dp),
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    text = "${snapshot.counts.total} followers",
                    color = PrimaryText,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.Bold,
                )
            }
        }
        if (entries.isEmpty()) {
            item(key = "followers-empty") {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.fillMaxWidth().padding(top = 60.dp),
                ) {
                    Icon(
                        imageVector = NostrVaultIcons.PeopleOutline,
                        contentDescription = null,
                        tint = colors.primary,
                        modifier = Modifier.size(40.dp),
                    )
                    Spacer(Modifier.height(8.dp))
                    Text(
                        text = "No followers here yet",
                        color = PrimaryText,
                        fontSize = 17.sp,
                        fontWeight = FontWeight.Bold,
                    )
                }
            }
        } else {
            items(entries, key = { it.pubkey }) { entry ->
                FollowerRow(
                    entry = entry,
                    profile = allProfiles[entry.pubkey],
                    onClick = { onProfileClick(entry.pubkey) },
                )
                HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)
            }
        }
    }
}

@Composable
private fun FollowerRow(
    entry: FollowerSnapshot.Entry,
    profile: FeedProfile?,
    onClick: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val name = profile?.bestName
        ?: remember(entry.pubkey) {
            (com.nostrvault.relay.HavenBridge.encodeNpub(entry.pubkey) ?: entry.pubkey).take(16) + "…"
        }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
    ) {
        AvatarImage(
            url = profile?.pictureURL,
            pubkey = entry.pubkey,
            size = 40.dp,
            displayName = profile?.bestName,
        )
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(
                text = name,
                color = PrimaryText,
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
            )
            profile?.nip05?.takeIf { it.isNotBlank() }?.let { nip05 ->
                Text(
                    text = nip05,
                    color = SecondaryText,
                    fontSize = 12.sp,
                    fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                    maxLines = 1,
                    overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                )
            }
        }
        if (entry.isNews) {
            Spacer(Modifier.width(8.dp))
            val tagColor = if (entry.isReturning) ZapOrange else colors.primary
            Text(
                text = if (entry.isReturning) "Returning" else "New",
                color = tagColor,
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                modifier = Modifier
                    .background(tagColor.copy(alpha = 0.16f), CircleShape)
                    .padding(horizontal = 8.dp, vertical = 3.dp),
            )
            Spacer(Modifier.width(8.dp))
            Text(
                text = formatTimestamp(entry.followedAt),
                color = SecondaryText,
                fontSize = 12.sp,
            )
        }
    }
}

/** The list on screen for the current view mode. */
private fun focusShownNotes(viewModel: DashboardViewModel): List<FeedNote> =
    when (viewModel.viewMode.value) {
        VaultViewMode.NOTES -> viewModel.displayNotes.value
        VaultViewMode.LIKES -> viewModel.displayLikedNotes.value
        VaultViewMode.ZAPS -> viewModel.displayZappedNotes.value
        VaultViewMode.FOLLOWERS -> emptyList()
    }

/**
 * Outlines the row a notification tap landed on, in the card's own shape, and
 * fades it out when cleared. Port of iOS `relayFocusOutline`.
 */
private fun Modifier.relayFocusOutline(isFocused: Boolean): Modifier = composed {
    val colors = LocalNostrVaultColors.current
    val alpha by animateFloatAsState(
        targetValue = if (isFocused) 1f else 0f,
        animationSpec = tween(durationMillis = if (isFocused) 200 else 600),
        label = "relayFocusOutline",
    )
    if (alpha == 0f) {
        Modifier
    } else {
        Modifier.border(
            width = 2.dp,
            color = colors.primary.copy(alpha = alpha),
            shape = RoundedCornerShape(12.dp),
        )
    }
}
