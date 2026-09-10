package com.nostrvault.ui.screens

import android.content.Intent
import android.util.Log
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.lifecycle.viewModelScope
import coil.compose.AsyncImage
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.*
import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.service.NostrEvent
import com.nostrvault.service.NostrService
import com.nostrvault.service.StatsService
import com.nostrvault.service.ZapValidationService
import com.nostrvault.ui.components.CustomZapSheet
import com.nostrvault.ui.components.GlassPill
import com.nostrvault.ui.components.GlassScaffold
import com.nostrvault.ui.components.reactionDisplayEmoji
import com.nostrvault.ui.components.reactionEmojiSummary
import com.nostrvault.ui.components.ScrollCondenseEffect
import com.nostrvault.ui.components.SkeletonFeed
import com.nostrvault.ui.components.VaultNoteCard
import com.nostrvault.ui.components.VaultNoteLayoutMode
import com.nostrvault.ui.components.VaultNoteType
import com.nostrvault.ui.navigation.Screen
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
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
) : ViewModel() {

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
        private const val SNAPSHOT_MAX_EVENTS = 500
        private const val SNAPSHOT_MAX_AGE_MS = 24 * 60 * 60 * 1000L // 24 hours
        private const val SNAPSHOT_FILE = "vault_snapshot.json"
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

    private val _isCompact = MutableStateFlow(false)
    val isCompact: StateFlow<Boolean> = _isCompact.asStateFlow()

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

    private var updateJob: Job? = null
    private var updateGeneration = 0
    private var maxDisplayedItems = 50

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
    }

    /** Clears all per-account event state and reconnects fresh. See init{}'s observer. */
    private fun resetForAccountSwitch() {
        disconnectFromLocalRelay()
        viewModelScope.launch {
            allEventsMutex.withLock { allEvents.clear() }
            seenIds.clear()
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
        val localUrl = "ws://127.0.0.1:${config.relayPort}"
        val macWss = config.macRelayWssURL

        outboxClient?.let { sendVaultSubscription(it, "vault-outbox", authors, ownerHex, localUrl) }
        inboxClient?.let { sendVaultSubscription(it, "vault-inbox", authors, ownerHex, "$localUrl/inbox") }
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
        val localUrl = "ws://127.0.0.1:${config.relayPort}"
        val inboxUrl = "$localUrl/inbox"
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

        val authorFilter = """{"kinds":[1,6,7,30023,9735],"authors":[$authorsJson]$sinceClause,"limit":500}"""

        val filters = if (ownerHex.isNotEmpty()) {
            // IMPORTANT: Mentions filter should NOT use sinceClause - we want ALL notes
            // where the user is tagged, not just recent ones. This fixes the bug where
            // older tagged notes never appear in the TAGGED filter.
            val mentionsFilter = """{"kinds":[1,6,7,30023,9735],"#p":["$ownerHex"],"limit":500}"""
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

        // For notes mode, try loading more from relay
        if (_viewMode.value == VaultViewMode.NOTES) {
            val oldest = currentNotes.lastOrNull()?.createdAt ?: return
            val config = configStore.config.value
            if (config.nostrURL == null) {
                Log.w(TAG, "loadMore: No relay URL configured")
                return
            }
            val localUrl = "ws://127.0.0.1:${config.relayPort}"

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
                val authorFilter = """{"kinds":[1,6,7,30023,9735],"authors":[$authorsJson],"until":$untilSecs,"limit":200}"""

                val filters = if (ownerHex.isNotEmpty()) {
                    val mentionsFilter = """{"kinds":[1,6,7,30023,9735],"#p":["$ownerHex"],"until":$untilSecs,"limit":300}"""
                    "$authorFilter,$mentionsFilter"
                } else {
                    authorFilter
                }

                // Query outbox
                val (outboxRaw, _) = queryRelayEndpoint(localUrl, filters, "outbox-hist", LOAD_MORE_TIMEOUT_MS)

                // Query inbox for older tagged notes
                val (inboxRaw, _) = queryRelayEndpoint("$localUrl/inbox", filters, "inbox-hist", LOAD_MORE_TIMEOUT_MS)

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

    fun toggleCompact() { _isCompact.value = !_isCompact.value }

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
        }
    }

    private suspend fun updateDisplayData(gen: Int) = withContext(Dispatchers.Default) {
        val currentMode = _viewMode.value
        val events = allEventsMutex.withLock { allEvents.toList() }
        val owner = nostrService.activeHexPubkey
        val whitelist = resolveWhitelistedHexPubkeys()

        // Partition once instead of re-scanning the full list per kind
        val noteEvents = ArrayList<NostrEvent>(events.size)
        val reactionEvents = ArrayList<NostrEvent>()
        val zapEvents = ArrayList<NostrEvent>()
        for (event in events) {
            when (event.kind) {
                1, 6, 30023 -> noteEvents.add(event)
                7 -> reactionEvents.add(event)
                9735 -> zapEvents.add(event)
            }
        }

        when (currentMode) {
            VaultViewMode.NOTES -> {
                val currentFilter = _contentFilter.value

                val filtered = noteEvents.filter { event ->
                    // Log all events before kind filtering to see what we're dropping
                    val hasUserPTag = event.tags.any { it.size >= 2 && it[0] == "p" && it[1] == owner }
                    if (hasUserPTag && event.pubkey != owner) {
                        Log.d(TAG, "Event with user p-tag BEFORE filter: id=${event.id.take(8)}, kind=${event.kind}, from=${event.pubkey.take(8)}")
                    }

                    if (event.kind !in listOf(1, 6, 30023)) {
                        if (hasUserPTag && event.pubkey != owner) {
                            Log.w(TAG, "DROPPING event kind ${event.kind} that tags user: id=${event.id.take(8)}")
                        }
                        return@filter false
                    }

                    when (currentFilter) {
                        VaultContentFilter.ALL -> {
                            val isMine = event.pubkey == owner
                            val isTagged = event.tags.any { it.size >= 2 && it[0] == "p" && it[1] == owner }
                            val isWhitelisted = whitelist.contains(event.pubkey)
                            isMine || isTagged || isWhitelisted
                        }
                        VaultContentFilter.MINE -> event.pubkey == owner
                        VaultContentFilter.TAGGED -> {
                            val tagged = event.pubkey != owner && event.tags.any { it.size >= 2 && it[0] == "p" && it[1] == owner }
                            if (tagged) {
                                Log.d(TAG, "TAGGED note included: id=${event.id.take(8)}, from=${event.pubkey.take(8)}, kind=${event.kind}")
                            }
                            tagged
                        }
                        VaultContentFilter.WHITELIST -> {
                            whitelist.contains(event.pubkey) && event.pubkey != owner
                        }
                    }
                }.sortedByDescending { it.createdAt }

                Log.d(TAG, "NOTES mode: filter=${currentFilter.displayName}, total=${filtered.size} notes, maxDisplayedItems=$maxDisplayedItems")

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
                    val targetNoteIds: Set<String> = when (currentLikesFilter) {
                        VaultLikesFilter.ON_MY_NOTES ->
                            noteEvents.filter { it.pubkey == owner }.map { it.id }.toSet()
                        VaultLikesFilter.ON_TAGGED ->
                            noteEvents.filter {
                                it.pubkey != owner &&
                                    it.tags.any { t -> t.size >= 2 && t[0] == "p" && t[1] == owner }
                            }.map { it.id }.toSet()
                        VaultLikesFilter.ON_WHITELISTED ->
                            noteEvents.filter { whitelist.contains(it.pubkey) }.map { it.id }.toSet()
                        else -> emptySet()
                    }

                    val excludeSelf = currentLikesFilter == VaultLikesFilter.ON_MY_NOTES
                    val rxMap = mutableMapOf<String, MutableList<Pair<String, String>>>()
                    val latestReaction = mutableMapOf<String, Long>()

                    for (event in reactionEvents) {
                        if (excludeSelf && event.pubkey == owner) continue
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

                if (currentZapsFilter == VaultZapsFilter.MY_ZAPS) {
                    val myZappedNoteIds = parsedReceipts
                        .filter { it.parsed.senderPubkey == owner }
                        .mapNotNull { it.parsed.targetNoteId }
                        .toSet()

                    val filtered = noteEvents.filter { myZappedNoteIds.contains(it.id) }
                    val displaySlice = filtered.take(maxDisplayedItems).map { event ->
                        FeedNote.fromEvent(event.id, event.pubkey, event.content, event.tags, event.createdAt, event.kind)
                    }

                    if (gen != updateGeneration) return@withContext
                    withContext(Dispatchers.Main.immediate) {
                        _displayZappedNotes.value = displaySlice
                        _zapMap.value = emptyMap()
                        if (displaySlice.isNotEmpty()) _zapsHasLoadedOnce.value = true
                    }
                } else {
                    // Incoming zaps on target note sets
                    val targetNoteIds: Set<String> = when (currentZapsFilter) {
                        VaultZapsFilter.ON_MY_NOTES ->
                            noteEvents.filter { it.pubkey == owner }.map { it.id }.toSet()
                        VaultZapsFilter.ON_TAGGED ->
                            noteEvents.filter {
                                it.pubkey != owner &&
                                    it.tags.any { t -> t.size >= 2 && t[0] == "p" && t[1] == owner }
                            }.map { it.id }.toSet()
                        VaultZapsFilter.ON_WHITELISTED ->
                            noteEvents.filter { whitelist.contains(it.pubkey) }.map { it.id }.toSet()
                        else -> emptySet()
                    }

                    val excludeSelf = currentZapsFilter == VaultZapsFilter.ON_MY_NOTES
                    val zMap = mutableMapOf<String, MutableList<Pair<String, Long>>>()

                    for (item in parsedReceipts) {
                        val targetId = item.parsed.targetNoteId ?: continue
                        if (!targetNoteIds.contains(targetId)) continue
                        if (excludeSelf && item.parsed.senderPubkey == owner) continue
                        zMap.getOrPut(targetId) { mutableListOf() }.add(Pair(item.parsed.senderPubkey, item.parsed.amountSats))
                    }

                    val zappedNoteIds = zMap.keys
                    val zapTotals = zMap.mapValues { (_, zappers) -> zappers.sumOf { it.second } }
                    val filtered = noteEvents
                        .filter { zappedNoteIds.contains(it.id) }
                        .sortedByDescending { zapTotals[it.id] ?: 0L }

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

            val likedNoteIds = events
                .filter { it.kind == 7 && it.pubkey == owner }
                .mapNotNull { event -> event.tags.firstOrNull { it.size >= 2 && it[0] == "e" }?.get(1) }
                .toSet()

            val existingIds = events.map { it.id }.toSet()
            val missingIds = likedNoteIds.subtract(existingIds).subtract(requestedMissingIds)
            if (missingIds.isEmpty()) return@launch

            for (id in missingIds) requestedMissingIds.add(id)
            Log.d(TAG, "Fetching ${missingIds.size} missing liked notes")

            val relayUrls = buildExternalRelayUrls()
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
        if (hasFetchedZapReceipts) return
        hasFetchedZapReceipts = true

        val localUrl = configStore.config.value.nostrURL ?: return
        val urls = mutableListOf(localUrl, "$localUrl/inbox")
        Log.d(TAG, "Fetching extended zap receipts history")
        nostrService.fetchZapReceipts(urls)
    }

    /** Merge events from NostrService.events into our allEvents store. */
    private suspend fun mergeNostrServiceEvents() {
        val serviceEvents = nostrService.events
        allEventsMutex.withLock {
            val existingIds = allEvents.map { it.id }.toHashSet()
            for (event in serviceEvents) {
                if (event.kind in listOf(1, 6, 7, 30023, 9735) && existingIds.add(event.id)) {
                    allEvents.add(event)
                    seenIds.add(event.id)
                }
            }
            trimAllEventsLocked()
        }
    }

    // ── Helpers ──────────────────────────────────────────────────

    private fun buildExternalRelayUrls(): List<String> {
        val urls = mutableListOf<String>()
        configStore.config.value.nostrURL?.let { urls.add(it) }
        val feedRelays = configStore.config.value.activeFeedRelays
        if (feedRelays.isNotEmpty()) {
            urls.addAll(feedRelays)
        } else {
            urls.addAll(listOf(
                "wss://relay.primal.net",
                "wss://nos.lol",
            ))
        }
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
            val targetId = event.tags.firstOrNull { it.size >= 2 && it[0] == "e" }?.get(1)

            var amountSats = 0L
            val reqTags = zapReq["tags"]?.jsonArray
            if (reqTags != null) {
                for (tag in reqTags) {
                    val tagArr = tag.jsonArray
                    if (tagArr.size >= 2 && tagArr[0].jsonPrimitive.contentOrNull == "amount") {
                        val msats = tagArr[1].jsonPrimitive.contentOrNull?.toLongOrNull()
                        if (msats != null) amountSats = msats / 1000
                        break
                    }
                }
            }

            val parsed = ParsedZapReceipt(senderPubkey, targetId, amountSats)
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
                            if (!seenIds.add(id)) return@collect

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

                            if (kind in listOf(1, 6, 30023)) {
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

@Composable
private fun IconFilterButton(
    icon: ImageVector,
    contentDescription: String,
    isSelected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalNostrVaultColors.current
    val tint by animateColorAsState(
        targetValue = if (isSelected) colors.primary else SecondaryText,
        animationSpec = Motion.control(),
        label = "filterTint",
    )
    IconButton(
        onClick = onClick,
        modifier = modifier.size(36.dp),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = contentDescription,
            tint = tint,
            modifier = Modifier.size(20.dp),
        )
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
    onCompose: () -> Unit,
    onReply: (String) -> Unit,
    onBack: () -> Unit,
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

    // Connection / loading
    val isRefreshing by viewModel.isRefreshing.collectAsState()
    val isLoadingMore by viewModel.isLoadingMore.collectAsState()
    val connectionColor by viewModel.connectionColor.collectAsState()
    val allProfiles by viewModel.profiles.collectAsState()
    val isCompact by viewModel.isCompact.collectAsState()
    val listState = rememberLazyListState()
    val context = LocalContext.current
    val colors = LocalNostrVaultColors.current

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

    // Scroll-direction detection → condense the bottom bar + Dashboard FAB.
    ScrollCondenseEffect(
        scrollKey = listState,
        firstVisibleItemIndex = { listState.firstVisibleItemIndex },
        firstVisibleItemScrollOffset = { listState.firstVisibleItemScrollOffset },
        setScrollingDown = feedService::setFeedScrollingDown,
    )

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
                // Leading pill: mode switcher (Notes / Likes / Zaps)
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
                }

                Spacer(Modifier.weight(1f))

                // Trailing pill: compact toggle + context-sensitive filters
                GlassPill {
                    IconFilterButton(
                        icon = if (isCompact) NostrVaultIcons.CompactView else NostrVaultIcons.ExpandedView,
                        contentDescription = if (isCompact) "Switch to expanded" else "Switch to compact",
                        isSelected = isCompact,
                        onClick = viewModel::toggleCompact,
                    )

                    when (viewMode) {
                        VaultViewMode.NOTES -> {
                            IconFilterButton(
                                icon = NostrVaultIcons.Layers,
                                contentDescription = "All",
                                isSelected = contentFilter == VaultContentFilter.ALL,
                                onClick = { viewModel.setContentFilter(VaultContentFilter.ALL) },
                            )
                            IconFilterButton(
                                icon = NostrVaultIcons.Profile,
                                contentDescription = "My Notes",
                                isSelected = contentFilter == VaultContentFilter.MINE,
                                onClick = { viewModel.setContentFilter(VaultContentFilter.MINE) },
                            )
                            IconFilterButton(
                                icon = NostrVaultIcons.At,
                                contentDescription = "Tagged",
                                isSelected = contentFilter == VaultContentFilter.TAGGED,
                                onClick = { viewModel.setContentFilter(VaultContentFilter.TAGGED) },
                            )
                            IconFilterButton(
                                icon = NostrVaultIcons.Verified,
                                contentDescription = "Whitelisted",
                                isSelected = contentFilter == VaultContentFilter.WHITELIST,
                                onClick = { viewModel.setContentFilter(VaultContentFilter.WHITELIST) },
                            )
                        }
                        VaultViewMode.LIKES -> {
                            IconFilterButton(
                                icon = NostrVaultIcons.Profile,
                                contentDescription = "My Notes",
                                isSelected = likesFilter == VaultLikesFilter.ON_MY_NOTES,
                                onClick = { viewModel.setLikesFilter(VaultLikesFilter.ON_MY_NOTES) },
                            )
                            IconFilterButton(
                                icon = NostrVaultIcons.At,
                                contentDescription = "Tagged",
                                isSelected = likesFilter == VaultLikesFilter.ON_TAGGED,
                                onClick = { viewModel.setLikesFilter(VaultLikesFilter.ON_TAGGED) },
                            )
                            IconFilterButton(
                                icon = NostrVaultIcons.Verified,
                                contentDescription = "Whitelisted",
                                isSelected = likesFilter == VaultLikesFilter.ON_WHITELISTED,
                                onClick = { viewModel.setLikesFilter(VaultLikesFilter.ON_WHITELISTED) },
                            )
                            IconFilterButton(
                                icon = NostrVaultIcons.Heart,
                                contentDescription = "My Likes",
                                isSelected = likesFilter == VaultLikesFilter.MY_LIKES,
                                onClick = { viewModel.setLikesFilter(VaultLikesFilter.MY_LIKES) },
                            )
                        }
                        VaultViewMode.ZAPS -> {
                            IconFilterButton(
                                icon = NostrVaultIcons.Profile,
                                contentDescription = "My Notes",
                                isSelected = zapsFilter == VaultZapsFilter.ON_MY_NOTES,
                                onClick = { viewModel.setZapsFilter(VaultZapsFilter.ON_MY_NOTES) },
                            )
                            IconFilterButton(
                                icon = NostrVaultIcons.At,
                                contentDescription = "Tagged",
                                isSelected = zapsFilter == VaultZapsFilter.ON_TAGGED,
                                onClick = { viewModel.setZapsFilter(VaultZapsFilter.ON_TAGGED) },
                            )
                            IconFilterButton(
                                icon = NostrVaultIcons.Verified,
                                contentDescription = "Whitelisted",
                                isSelected = zapsFilter == VaultZapsFilter.ON_WHITELISTED,
                                onClick = { viewModel.setZapsFilter(VaultZapsFilter.ON_WHITELISTED) },
                            )
                            IconFilterButton(
                                icon = NostrVaultIcons.Zap,
                                contentDescription = "My Zaps",
                                isSelected = zapsFilter == VaultZapsFilter.MY_ZAPS,
                                onClick = { viewModel.setZapsFilter(VaultZapsFilter.MY_ZAPS) },
                            )
                        }
                    }
                }
            }
        },
        floatingActionButton = {
            val scrollingDown by feedService.feedScrollingDown.collectAsState()
            // The FAB hides and shows with the scroll, so it is chrome.
            val fabSpring = Motion.chrome<Float>()
            AnimatedVisibility(
                visible = !scrollingDown,
                enter = scaleIn(animationSpec = fabSpring, initialScale = 0.5f) + fadeIn(fabSpring),
                exit = scaleOut(animationSpec = fabSpring, targetScale = 0.5f) + fadeOut(fabSpring),
            ) {
                Surface(
                    onClick = {
                        viewModel.loadStats()
                        showDashboardSheet = true
                    },
                    modifier = Modifier.padding(bottom = 88.dp),
                    color = dotColor,
                    shape = CircleShape,
                    shadowElevation = 8.dp,
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.padding(horizontal = 18.dp, vertical = 12.dp),
                    ) {
                        Icon(
                            imageVector = NostrVaultIcons.Relay,
                            contentDescription = null,
                            tint = PrimaryText,
                            modifier = Modifier.size(18.dp),
                        )
                        Spacer(Modifier.width(6.dp))
                        Text(
                            text = "Dashboard",
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
                    isCompact = isCompact,
                    isLoadingMore = isLoadingMore,
                    listState = listState,
                    allProfiles = allProfiles,
                    padding = padding,
                    viewModel = viewModel,
                    onNoteClick = onNoteClick,
                    onArticleClick = onArticleClick,
                    onProfileClick = onProfileClick,
                )
                VaultViewMode.LIKES -> LikesContent(
                    notes = displayLikedNotes,
                    quotedNotes = quotedNotes,
                    reactionMap = reactionMap,
                    hasLoadedOnce = likesHasLoadedOnce,
                    isRefreshing = isRefreshing,
                    isCompact = isCompact,
                    likesFilter = likesFilter,
                    listState = listState,
                    allProfiles = allProfiles,
                    padding = padding,
                    viewModel = viewModel,
                    onNoteClick = onNoteClick,
                    onArticleClick = onArticleClick,
                    onProfileClick = onProfileClick,
                )
                VaultViewMode.ZAPS -> ZapsContent(
                    notes = displayZappedNotes,
                    quotedNotes = quotedNotes,
                    zapMap = zapMap,
                    hasLoadedOnce = zapsHasLoadedOnce,
                    isRefreshing = isRefreshing,
                    isCompact = isCompact,
                    zapsFilter = zapsFilter,
                    listState = listState,
                    allProfiles = allProfiles,
                    padding = padding,
                    viewModel = viewModel,
                    onNoteClick = onNoteClick,
                    onArticleClick = onArticleClick,
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
                    onNavigate(Screen.LogViewer)
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
                onImportNotes = { viewModel.importNotes(context) },
                onExportJsonl = { viewModel.exportJsonl(context) },
                onExportMedia = { viewModel.exportMedia(context) },
                onDismissImport = viewModel::dismissImport,
                showReposts = feedService.showReposts.collectAsState().value,
                showReplies = feedService.showReplies.collectAsState().value,
                autoLoadNewNotes = true, // Default; auto-load state lives in FeedViewModel
                feedRelays = currentConfig.activeFeedRelays,
                onToggleReposts = { feedService.setShowReposts(it) },
                onToggleReplies = { feedService.setShowReplies(it) },
                onToggleAutoLoad = { /* auto-load managed by FeedViewModel */ },
                onManageRelays = {
                    showDashboardSheet = false
                    onNavigate(Screen.RelayListEditor)
                },
            )
        }
    }

    // Zap sheet
    if (zapNoteId != null) {
        CustomZapSheet(
            sheetState = zapSheetState,
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
    isCompact: Boolean,
    isLoadingMore: Boolean,
    listState: androidx.compose.foundation.lazy.LazyListState,
    allProfiles: Map<String, FeedProfile>,
    padding: PaddingValues,
    viewModel: DashboardViewModel,
    onNoteClick: (String) -> Unit,
    onArticleClick: (String) -> Unit,
    onProfileClick: (String) -> Unit,
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
                    layoutMode = if (isCompact) VaultNoteLayoutMode.COMPACT else VaultNoteLayoutMode.EXPANDED,
                    onNoteClick = onNoteClick,
                    onArticleClick = onArticleClick,
                    onProfileClick = onProfileClick,
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = if (isCompact) 2.dp else 4.dp),
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
    isCompact: Boolean,
    likesFilter: VaultLikesFilter,
    listState: androidx.compose.foundation.lazy.LazyListState,
    allProfiles: Map<String, FeedProfile>,
    padding: PaddingValues,
    viewModel: DashboardViewModel,
    onNoteClick: (String) -> Unit,
    onArticleClick: (String) -> Unit,
    onProfileClick: (String) -> Unit,
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
                    layoutMode = if (isCompact) VaultNoteLayoutMode.COMPACT else VaultNoteLayoutMode.EXPANDED,
                    onNoteClick = onNoteClick,
                    onArticleClick = onArticleClick,
                    onProfileClick = onProfileClick,
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = if (isCompact) 2.dp else 4.dp),
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
    isCompact: Boolean,
    zapsFilter: VaultZapsFilter,
    listState: androidx.compose.foundation.lazy.LazyListState,
    allProfiles: Map<String, FeedProfile>,
    padding: PaddingValues,
    viewModel: DashboardViewModel,
    onNoteClick: (String) -> Unit,
    onArticleClick: (String) -> Unit,
    onProfileClick: (String) -> Unit,
) {
    val colors = LocalNostrVaultColors.current

    // Settle-driven loading: hasLoadedOnce is set either when zaps arrive or by a
    // bounded ~6s settle (armZapsSettle), so the spinner never hangs forever when
    // there are simply no zaps. Don't gate on isRefreshing here.
    if (notes.isEmpty() && !hasLoadedOnce) {
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
                    layoutMode = if (isCompact) VaultNoteLayoutMode.COMPACT else VaultNoteLayoutMode.EXPANDED,
                    onNoteClick = onNoteClick,
                    onArticleClick = onArticleClick,
                    onProfileClick = onProfileClick,
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = if (isCompact) 2.dp else 4.dp),
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
    onImportNotes: () -> Unit,
    onExportJsonl: () -> Unit,
    onExportMedia: () -> Unit,
    onDismissImport: () -> Unit,
    showReposts: Boolean,
    showReplies: Boolean,
    autoLoadNewNotes: Boolean,
    feedRelays: List<String>,
    onToggleReposts: (Boolean) -> Unit,
    onToggleReplies: (Boolean) -> Unit,
    onToggleAutoLoad: (Boolean) -> Unit,
    onManageRelays: () -> Unit,
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

            var showFeedConfig by remember { mutableStateOf(false) }

            IconButton(onClick = { showFeedConfig = true }, modifier = Modifier.size(32.dp)) {
                Icon(
                    NostrVaultIcons.Settings,
                    "Feed Settings",
                    tint = SecondaryText,
                    modifier = Modifier.size(18.dp),
                )
            }
            IconButton(onClick = onRefresh, modifier = Modifier.size(32.dp)) {
                Icon(
                    NostrVaultIcons.Refresh,
                    "Refresh",
                    tint = SecondaryText,
                    modifier = Modifier.size(18.dp),
                )
            }

            if (showFeedConfig) {
                com.nostrvault.ui.screens.dashboard.FeedConfigSheet(
                    showReposts = showReposts,
                    showReplies = showReplies,
                    autoLoadNewNotes = autoLoadNewNotes,
                    feedRelays = feedRelays,
                    onToggleReposts = onToggleReposts,
                    onToggleReplies = onToggleReplies,
                    onToggleAutoLoad = onToggleAutoLoad,
                    onManageRelays = {
                        showFeedConfig = false
                        onManageRelays()
                    },
                    onDismiss = { showFeedConfig = false },
                )
            }
        }

        // Relay status header
        com.nostrvault.ui.screens.dashboard.RelayStatusHeader(
            relayStatus = relayStatus,
            relayAddress = relayAddress,
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
                onImportNotes = onImportNotes,
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
