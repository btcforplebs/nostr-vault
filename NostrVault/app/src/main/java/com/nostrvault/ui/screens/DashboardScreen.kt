package com.nostrvault.ui.screens

import android.content.Intent
import android.util.Log
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
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
import com.nostrvault.ui.components.CustomZapSheet
import com.nostrvault.ui.components.GlassPill
import com.nostrvault.ui.components.GlassScaffold
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
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*
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
    private var localClient: WebSocketClient? = null

    private val zapReceiptCache = ConcurrentHashMap<String, ParsedZapReceipt>()
    private val requestedMissingIds = ConcurrentHashMap.newKeySet<String>()
    private val requestedMissingZapNoteIds = ConcurrentHashMap.newKeySet<String>()
    private var hasFetchedZapReceipts = false

    private var updateJob: Job? = null
    private var updateGeneration = 0
    private var maxDisplayedItems = 50

    private var connectionRetryCount = 0

    init {
        loadStats()

        // Fallback: readyForConnections fires 3s after RUNNING. If the
        // relayStatus RUNNING handler below already connected, _isRefreshing
        // will be true and we skip the duplicate call.
        viewModelScope.launch {
            RelayForegroundService.readyForConnections.collect { ready ->
                Log.d(TAG, "readyForConnections=$ready, notesLoaded=${_notesHasLoadedOnce.value}, color=${_connectionColor.value}")
                if (ready && !_notesHasLoadedOnce.value && !_isRefreshing.value) {
                    loadLocalRelayNotes()
                }
            }
        }

        // Connect as soon as relay is RUNNING — no 3s wait. The relay's TCP
        // health check already passed before this status is set, so the
        // WebSocket endpoint is reachable.
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
                        if (!_notesHasLoadedOnce.value && !_isRefreshing.value) {
                            loadLocalRelayNotes()
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
    }

    /**
     * Called when the app returns to the foreground.
     * Re-establishes WebSocket connection to the local relay if needed.
     */
    fun onResume() {
        val relayUp = RelayForegroundService.relayStatus.value == RelayForegroundService.RelayStatus.RUNNING
        val needsReconnect = _connectionColor.value != "green" || localClient == null
        if (relayUp && needsReconnect && !_isRefreshing.value) {
            loadLocalRelayNotes()
        }
        // Always refresh stats on resume
        loadStats()
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

    fun loadLocalRelayNotes() {
        val config = configStore.config.value
        if (config.nostrURL == null) {
            _connectionStatus.value = "No local relay"
            _connectionColor.value = "red"
            return
        }

        // Pull-to-refresh: ask the embedded relay to fetch newly tagged events
        // (replies, reactions, zaps, reposts, mentions, DMs) and the owner's own
        // notes from external relays into the local DBs. Injected events then
        // stream in over the local subscription opened just below. Non-blocking.
        runCatching { com.nostrvault.relay.HavenBridge.requestRelaySync() }
            .onFailure { Log.w(TAG, "requestRelaySync failed: ${it.message}") }
        // For local relay, always use plain ws:// to match the TLS-disabled
        // Go relay. Localhost is exempt from Android cleartext restrictions.
        val localUrl = "ws://127.0.0.1:${config.relayPort}"

        // Build author set: owner + whitelisted pubkeys
        val ownerHex = nostrService.activeHexPubkey
        val authors = mutableSetOf<String>()
        if (ownerHex.isNotEmpty()) authors.add(ownerHex)
        config.whitelistedNpubs?.forEach { npub ->
            nostrService.npubToHex(npub)?.let { authors.add(it) }
        }

        Log.d(TAG, "loadLocalRelayNotes: url=$localUrl, authors=${authors.size}, ownerHex=${ownerHex.take(16)}...")

        _isRefreshing.value = true
        _connectionStatus.value = "Connecting..."
        _connectionColor.value = "yellow"
        seenIds.clear()

        viewModelScope.launch(Dispatchers.IO) {
            localClient?.disconnect()
            allEventsMutex.withLock { allEvents.clear() }

            val contentNotes = mutableListOf<FeedNote>()
            val rawEvents = mutableListOf<NostrEvent>()
            val client = WebSocketClient(url = localUrl, scope = viewModelScope, trustLocalhost = true)
            localClient = client
            val subId = "local-vault-${UUID.randomUUID().toString().take(8)}"
            var eoseReceived = false

            val collectJob = launch {
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

                                // Process metadata events via NostrService
                                if (kind in listOf(0, 10002, 10050, 10063, 10000)) {
                                    nostrService.processRelayMessage(msg, localUrl)
                                    return@collect
                                }

                                // Store all non-metadata events for vault processing
                                val nostrEvent = NostrEvent(
                                    id = id,
                                    pubkey = pubkey,
                                    createdAt = createdAt,
                                    kind = kind,
                                    tags = tags,
                                    content = content,
                                    sig = sig,
                                )
                                rawEvents.add(nostrEvent)

                                // Build FeedNote list for content notes
                                if (kind in listOf(1, 6, 30023)) {
                                    val note = FeedNote.fromEvent(id, pubkey, content, tags, createdAt, kind)
                                    if (!note.isNoiseOrSpam()) {
                                        contentNotes.add(note)
                                    }
                                }

                                // Fetch profiles for reactors and zappers
                                nostrService.fetchMissingProfiles(listOf(pubkey))
                            }
                            "EOSE" -> {
                                eoseReceived = true
                            }
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "Parse error: ${e.message}")
                    }
                }
            }

            Log.d(TAG, "Connecting WebSocket to $localUrl...")
            client.connect()

            // Wait for connection
            var waited = 0L
            while (client.connectionState.value != WebSocketClient.ConnectionState.CONNECTED && waited < 5000) {
                delay(100)
                waited += 100
            }

            if (client.connectionState.value == WebSocketClient.ConnectionState.CONNECTED) {
                Log.d(TAG, "Connected to local relay, sending subscription with ${authors.size} authors")
                withContext(Dispatchers.Main.immediate) {
                    _connectionStatus.value = "Loading..."
                    _connectionColor.value = "yellow"
                }

                // Build author-scoped filters to fetch the owner's notes and engagement
                val authorsJson = authors.joinToString(",") { "\"$it\"" }
                val authorFilter = """{"kinds":[1,6,7,30023,9735],"authors":[$authorsJson],"limit":500}"""

                val filters = if (ownerHex.isNotEmpty()) {
                    // Second filter: notes/reactions mentioning the owner
                    val mentionsFilter = """{"kinds":[1,6,7,30023,9735],"#p":["$ownerHex"],"limit":200}"""
                    "$authorFilter,$mentionsFilter"
                } else {
                    authorFilter
                }

                val sent = client.send("[\"REQ\",\"$subId\",$filters]")
                if (!sent) {
                    Log.w(TAG, "send() returned false -- subscription not delivered")
                    withContext(Dispatchers.Main.immediate) {
                        _connectionStatus.value = "Offline"
                        _connectionColor.value = "red"
                        _isRefreshing.value = false
                    }
                    collectJob.cancel()
                    client.disconnect()
                    return@launch
                }

                // Wait for EOSE or timeout
                val deadline = System.currentTimeMillis() + LOAD_TIMEOUT_MS
                while (!eoseReceived && System.currentTimeMillis() < deadline) {
                    delay(200)
                }

                // Query inbox for tagged notes (stored in separate DB on the relay)
                val inboxUrl = "$localUrl/inbox"
                Log.d(TAG, "Querying inbox at $inboxUrl for tagged notes...")
                val (inboxRaw, inboxNotes) = queryRelayEndpoint(inboxUrl, filters, "local-inbox", LOAD_TIMEOUT_MS)
                rawEvents.addAll(inboxRaw)
                contentNotes.addAll(inboxNotes)
                Log.d(TAG, "Inbox complete: ${inboxRaw.size} events, ${inboxNotes.size} notes")

                Log.d(TAG, "Load complete: eoseReceived=$eoseReceived, rawEvents=${rawEvents.size}, contentNotes=${contentNotes.size}")

                // Store all events
                allEventsMutex.withLock {
                    allEvents.addAll(rawEvents)
                }

                withContext(Dispatchers.Main.immediate) {
                    val sorted = contentNotes.sortedByDescending { it.createdAt }.take(MAX_LOCAL_NOTES)
                    _displayNotes.value = sorted
                    _connectionStatus.value = "Local (${sorted.size})"
                    _connectionColor.value = "green"
                    _isRefreshing.value = false
                    _notesHasLoadedOnce.value = true
                    connectionRetryCount = 0
                }

                // Trigger display data update for current mode
                scheduleUpdateDisplayData()
            } else {
                val errorDetail = client.lastError ?: "timeout"
                Log.w(TAG, "Connection failed after ${waited}ms (state=${client.connectionState.value}, error=$errorDetail)")
                collectJob.cancel()
                client.disconnect()

                // Single retry: wait 3s and try again if relay is still ready
                if (connectionRetryCount < 1 && RelayForegroundService.readyForConnections.value) {
                    connectionRetryCount++
                    Log.d(TAG, "Scheduling retry in 3s (attempt $connectionRetryCount)")
                    withContext(Dispatchers.Main.immediate) {
                        _connectionStatus.value = "Retrying..."
                        _connectionColor.value = "yellow"
                        _isRefreshing.value = false
                    }
                    delay(3000)
                    if (RelayForegroundService.readyForConnections.value && !_notesHasLoadedOnce.value) {
                        loadLocalRelayNotes()
                    } else {
                        withContext(Dispatchers.Main.immediate) {
                            _connectionStatus.value = "Offline"
                            _connectionColor.value = "red"
                        }
                        connectionRetryCount = 0
                    }
                } else {
                    withContext(Dispatchers.Main.immediate) {
                        // Show error detail in status for debugging
                        _connectionStatus.value = if (errorDetail.length > 30) {
                            "Err: ${errorDetail.take(30)}..."
                        } else {
                            "Err: $errorDetail"
                        }
                        _connectionColor.value = "red"
                        _isRefreshing.value = false
                    }
                    connectionRetryCount = 0
                }
                return@launch
            }

            collectJob.cancel()
            client.disconnect()
        }
    }

    fun loadMore() {
        if (_isLoadingMore.value) return
        val currentNotes = _displayNotes.value
        if (currentNotes.isEmpty()) return

        // For notes mode, try loading more from relay
        if (_viewMode.value == VaultViewMode.NOTES) {
            val oldest = currentNotes.lastOrNull()?.createdAt ?: return
            val config = configStore.config.value
            if (config.nostrURL == null) return
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
                    val mentionsFilter = """{"kinds":[1,6,7,30023,9735],"#p":["$ownerHex"],"until":$untilSecs,"limit":100}"""
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
        scheduleUpdateDisplayData()
        if (filter == VaultZapsFilter.MY_ZAPS) fetchMissingZappedNotes()
    }

    fun toggleCompact() { _isCompact.value = !_isCompact.value }

    // ── Display data processing (port of iOS VaultDataProcessing) ──

    private fun scheduleUpdateDisplayData() {
        updateJob?.cancel()
        updateGeneration++
        val gen = updateGeneration
        updateJob = viewModelScope.launch {
            delay(150) // 150ms debounce matching iOS
            if (gen != updateGeneration) return@launch
            updateDisplayData(gen)
        }
    }

    private suspend fun updateDisplayData(gen: Int) = withContext(Dispatchers.Default) {
        val currentMode = _viewMode.value
        val events = allEventsMutex.withLock { allEvents.toList() }
        val owner = nostrService.activeHexPubkey
        val whitelist = resolveWhitelistedHexPubkeys()
        val noteKinds = listOf(1, 6, 30023)

        when (currentMode) {
            VaultViewMode.NOTES -> {
                val currentFilter = _contentFilter.value

                val filtered = events.filter { event ->
                    if (event.kind !in listOf(1, 30023)) return@filter false

                    when (currentFilter) {
                        VaultContentFilter.ALL -> {
                            val isMine = event.pubkey == owner
                            val isTagged = event.tags.any { it.size >= 2 && it[0] == "p" && it[1] == owner }
                            val isWhitelisted = whitelist.contains(event.pubkey)
                            isMine || isTagged || isWhitelisted
                        }
                        VaultContentFilter.MINE -> event.pubkey == owner
                        VaultContentFilter.TAGGED -> {
                            event.pubkey != owner && event.tags.any { it.size >= 2 && it[0] == "p" && it[1] == owner }
                        }
                        VaultContentFilter.WHITELIST -> {
                            whitelist.contains(event.pubkey) && event.pubkey != owner
                        }
                    }
                }.sortedByDescending { it.createdAt }

                // Convert to FeedNote for display
                val displaySlice = filtered.take(maxDisplayedItems).map { event ->
                    FeedNote.fromEvent(event.id, event.pubkey, event.content, event.tags, event.createdAt, event.kind)
                }.filter { !it.isNoiseOrSpam() }

                val displayedIds = displaySlice.map { it.id }.toSet()

                // Build reaction map for displayed notes
                val rxMap = mutableMapOf<String, MutableList<Pair<String, String>>>()
                for (event in events) {
                    if (event.kind != 7) continue
                    val targetId = event.tags.firstOrNull { it.size >= 2 && it[0] == "e" && displayedIds.contains(it[1]) }?.get(1) ?: continue
                    val emoji = if (event.content.isEmpty()) "+" else event.content
                    rxMap.getOrPut(targetId) { mutableListOf() }.add(Pair(event.pubkey, emoji))
                }

                // Build zap map for displayed notes
                val zMap = mutableMapOf<String, MutableList<Pair<String, Long>>>()
                for (event in events) {
                    if (event.kind != 9735) continue
                    val targetId = event.tags.firstOrNull { it.size >= 2 && it[0] == "e" && displayedIds.contains(it[1]) }?.get(1) ?: continue
                    val parsed = parseZapReceipt(event) ?: continue
                    zMap.getOrPut(targetId) { mutableListOf() }.add(Pair(parsed.senderPubkey, parsed.amountSats))
                }

                if (gen != updateGeneration) return@withContext
                withContext(Dispatchers.Main.immediate) {
                    _displayNotes.value = displaySlice
                    _reactionMap.value = rxMap
                    _zapMap.value = zMap
                    _notesHasLoadedOnce.value = true
                    _connectionStatus.value = "Local (${displaySlice.size})"
                }
            }

            VaultViewMode.LIKES -> {
                val currentLikesFilter = _likesFilter.value

                if (currentLikesFilter == VaultLikesFilter.MY_LIKES) {
                    // My Likes: notes I reacted to
                    val myLikeDates = mutableMapOf<String, Long>()
                    for (event in events) {
                        if (event.kind != 7 || event.pubkey != owner) continue
                        val targetId = event.tags.firstOrNull { it.size >= 2 && it[0] == "e" }?.get(1) ?: continue
                        val existing = myLikeDates[targetId]
                        if (existing == null || event.createdAt > existing) {
                            myLikeDates[targetId] = event.createdAt
                        }
                    }

                    val myLikedNoteIds = myLikeDates.keys
                    val filtered = events
                        .filter { it.kind in noteKinds && myLikedNoteIds.contains(it.id) }
                        .sortedByDescending { myLikeDates[it.id] ?: 0L }

                    val displaySlice = filtered.take(maxDisplayedItems).map { event ->
                        FeedNote.fromEvent(event.id, event.pubkey, event.content, event.tags, event.createdAt, event.kind)
                    }

                    if (gen != updateGeneration) return@withContext
                    withContext(Dispatchers.Main.immediate) {
                        _displayLikedNotes.value = displaySlice
                        _reactionMap.value = emptyMap()
                        if (displaySlice.isNotEmpty()) _likesHasLoadedOnce.value = true
                    }
                } else {
                    // Incoming reactions on target note sets
                    val targetNoteIds: Set<String> = when (currentLikesFilter) {
                        VaultLikesFilter.ON_MY_NOTES ->
                            events.filter { it.pubkey == owner && it.kind in noteKinds }.map { it.id }.toSet()
                        VaultLikesFilter.ON_TAGGED ->
                            events.filter {
                                it.kind in noteKinds && it.pubkey != owner &&
                                    it.tags.any { t -> t.size >= 2 && t[0] == "p" && t[1] == owner }
                            }.map { it.id }.toSet()
                        VaultLikesFilter.ON_WHITELISTED ->
                            events.filter { it.kind in noteKinds && whitelist.contains(it.pubkey) }.map { it.id }.toSet()
                        else -> emptySet()
                    }

                    val excludeSelf = currentLikesFilter == VaultLikesFilter.ON_MY_NOTES
                    val rxMap = mutableMapOf<String, MutableList<Pair<String, String>>>()
                    val latestReaction = mutableMapOf<String, Long>()

                    for (event in events) {
                        if (event.kind != 7) continue
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
                    val filtered = events
                        .filter { it.kind in noteKinds && likedNoteIds.contains(it.id) }
                        .sortedWith(compareByDescending<NostrEvent> { latestReaction[it.id] ?: 0L }
                            .thenByDescending { it.createdAt })

                    val displaySlice = filtered.take(maxDisplayedItems).map { event ->
                        FeedNote.fromEvent(event.id, event.pubkey, event.content, event.tags, event.createdAt, event.kind)
                    }

                    if (gen != updateGeneration) return@withContext
                    withContext(Dispatchers.Main.immediate) {
                        _displayLikedNotes.value = displaySlice
                        _reactionMap.value = rxMap
                        if (displaySlice.isNotEmpty()) _likesHasLoadedOnce.value = true
                    }
                }
            }

            VaultViewMode.ZAPS -> {
                val currentZapsFilter = _zapsFilter.value
                val zapReceipts = events.filter { it.kind == 9735 }

                // Parse all zap receipts (with caching)
                data class ParsedEntry(val receiptId: String, val parsed: ParsedZapReceipt)
                val parsedReceipts = mutableListOf<ParsedEntry>()
                for (receipt in zapReceipts) {
                    val parsed = parseZapReceipt(receipt) ?: continue
                    parsedReceipts.add(ParsedEntry(receipt.id, parsed))
                }

                if (currentZapsFilter == VaultZapsFilter.MY_ZAPS) {
                    val myZappedNoteIds = parsedReceipts
                        .filter { it.parsed.senderPubkey == owner }
                        .mapNotNull { it.parsed.targetNoteId }
                        .toSet()

                    val filtered = events.filter { it.kind in noteKinds && myZappedNoteIds.contains(it.id) }
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
                            events.filter { it.pubkey == owner && it.kind in noteKinds }.map { it.id }.toSet()
                        VaultZapsFilter.ON_TAGGED ->
                            events.filter {
                                it.kind in noteKinds && it.pubkey != owner &&
                                    it.tags.any { t -> t.size >= 2 && t[0] == "p" && t[1] == owner }
                            }.map { it.id }.toSet()
                        VaultZapsFilter.ON_WHITELISTED ->
                            events.filter { it.kind in noteKinds && whitelist.contains(it.pubkey) }.map { it.id }.toSet()
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
                    val filtered = events
                        .filter { it.kind in noteKinds && zappedNoteIds.contains(it.id) }
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
                "wss://relay.damus.io",
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
            return parsed
        } catch (_: Exception) {
            return null
        }
    }

    fun profileFor(pubkey: String): FeedProfile? = profiles.value[pubkey]

    fun currentUserPubkey(): String = nostrService.activeHexPubkey

    fun isWhitelisted(pubkey: String): Boolean =
        resolveWhitelistedHexPubkeys().contains(pubkey)

    fun getReactionDate(noteId: String, reactorPubkey: String): java.util.Date? {
        val events = runBlocking { allEventsMutex.withLock { allEvents.toList() } }
        return events
            .filter { event ->
                event.kind == 7 &&
                event.tags.any { tag -> tag.size >= 2 && tag[0] == "e" && tag[1] == noteId } &&
                event.pubkey == reactorPubkey
            }
            .maxOfOrNull { event -> java.util.Date(event.createdAt * 1000) }
    }

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

    override fun onCleared() {
        super.onCleared()
        localClient?.disconnect()
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
        animationSpec = tween(durationMillis = 150),
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
    val contentFilter by viewModel.contentFilter.collectAsState()
    val likesFilter by viewModel.likesFilter.collectAsState()
    val zapsFilter by viewModel.zapsFilter.collectAsState()

    // Display data
    val displayNotes by viewModel.displayNotes.collectAsState()
    val displayLikedNotes by viewModel.displayLikedNotes.collectAsState()
    val displayZappedNotes by viewModel.displayZappedNotes.collectAsState()
    val reactionMap by viewModel.reactionMap.collectAsState()
    val zapMap by viewModel.zapMap.collectAsState()
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
            lastVisible >= listState.layoutInfo.totalItemsCount - 5
        }
    }
    LaunchedEffect(shouldLoadMore) {
        if (shouldLoadMore) viewModel.loadMore()
    }

    // Reconnect to local relay when the app returns to the foreground
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        viewModel.onResume()
    }

    // Start/stop log polling based on relay status
    val logRelayStatus by RelayForegroundService.relayStatus.collectAsState()
    LaunchedEffect(logRelayStatus) {
        when (logRelayStatus) {
            RelayForegroundService.RelayStatus.BOOTING,
            RelayForegroundService.RelayStatus.IMPORTING,
            RelayForegroundService.RelayStatus.RUNNING -> logStore.startPolling(this)
            RelayForegroundService.RelayStatus.OFFLINE -> logStore.stopPolling()
        }
    }

    // Connection dot color for FAB
    val dotColor = when (connectionColor) {
        "green" -> SuccessGreen
        "yellow", "orange" -> ZapOrange
        "red" -> ErrorRed
        else -> SecondaryText
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
                    IconFilterButton(
                        icon = NostrVaultIcons.HeartFilled,
                        contentDescription = "Likes",
                        isSelected = viewMode == VaultViewMode.LIKES,
                        onClick = { viewModel.setViewMode(VaultViewMode.LIKES) },
                    )
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
        },
    ) { padding ->
        PullToRefreshBox(
            isRefreshing = isRefreshing,
            onRefresh = viewModel::loadLocalRelayNotes,
            modifier = Modifier.fillMaxSize(),
        ) {
            when (viewMode) {
                VaultViewMode.NOTES -> NotesContent(
                    notes = displayNotes,
                    reactionMap = reactionMap,
                    zapMap = zapMap,
                    isRefreshing = isRefreshing,
                    hasLoadedOnce = notesHasLoadedOnce,
                    isCompact = isCompact,
                    isLoadingMore = isLoadingMore,
                    listState = listState,
                    allProfiles = allProfiles,
                    padding = padding,
                    viewModel = viewModel,
                    onNoteClick = onNoteClick,
                    onProfileClick = onProfileClick,
                )
                VaultViewMode.LIKES -> LikesContent(
                    notes = displayLikedNotes,
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
                    onProfileClick = onProfileClick,
                )
                VaultViewMode.ZAPS -> ZapsContent(
                    notes = displayZappedNotes,
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
                cacheDir = viewModel.configStore.config.value.appSupportDir?.let { "$it/media_cache" },
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
                feedRelays = viewModel.configStore.config.value.activeFeedRelays,
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
    reactionMap: Map<String, List<Pair<String, String>>>,
    zapMap: Map<String, List<Pair<String, Long>>>,
    isRefreshing: Boolean,
    hasLoadedOnce: Boolean,
    isCompact: Boolean,
    isLoadingMore: Boolean,
    listState: androidx.compose.foundation.lazy.LazyListState,
    allProfiles: Map<String, FeedProfile>,
    padding: PaddingValues,
    viewModel: DashboardViewModel,
    onNoteClick: (String) -> Unit,
    onProfileClick: (String) -> Unit,
) {
    val colors = LocalNostrVaultColors.current

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
                    profile = viewModel.profileFor(note.pubkey),
                    profiles = allProfiles,
                    reactors = reactionMap[note.id] ?: emptyList(),
                    latestReactionDate = reactionMap[note.id]?.mapNotNull {
                        viewModel.getReactionDate(note.id, it.first)
                    }?.maxOrNull(),
                    zappers = zapMap[note.id] ?: emptyList(),
                    noteType = noteType,
                    layoutMode = if (isCompact) VaultNoteLayoutMode.COMPACT else VaultNoteLayoutMode.EXPANDED,
                    onNoteClick = onNoteClick,
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
    onProfileClick: (String) -> Unit,
) {
    val colors = LocalNostrVaultColors.current

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
                    profile = viewModel.profileFor(note.pubkey),
                    profiles = allProfiles,
                    reactors = reactionMap[note.id] ?: emptyList(),
                    latestReactionDate = reactionMap[note.id]?.mapNotNull {
                        viewModel.getReactionDate(note.id, it.first)
                    }?.maxOrNull(),
                    noteType = noteType,
                    layoutMode = if (isCompact) VaultNoteLayoutMode.COMPACT else VaultNoteLayoutMode.EXPANDED,
                    onNoteClick = onNoteClick,
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
    onProfileClick: (String) -> Unit,
) {
    val colors = LocalNostrVaultColors.current

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
                    profile = viewModel.profileFor(note.pubkey),
                    profiles = allProfiles,
                    zappers = zapMap[note.id] ?: emptyList(),
                    noteType = noteType,
                    layoutMode = if (isCompact) VaultNoteLayoutMode.COMPACT else VaultNoteLayoutMode.EXPANDED,
                    onNoteClick = onNoteClick,
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
        Icon(
            imageVector = NostrVaultIcons.HeartFilled,
            contentDescription = null,
            tint = LikeRed,
            modifier = Modifier.size(12.dp),
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

        // "name1, name2 liked"
        val names = unique.take(3).map { (pubkey, _) ->
            profiles[pubkey]?.bestName ?: "npub\u2026${pubkey.takeLast(4)}"
        }
        val remaining = unique.size - names.size
        val text = buildString {
            append(names.joinToString(", "))
            if (remaining > 0) append(" +$remaining more")
            append(" liked")
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
