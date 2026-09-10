package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.CredentialStore
import com.nostrvault.data.local.ProfileRepository
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.GlobalSearchCollector
import com.nostrvault.data.model.GlobalSearchResults
import com.nostrvault.data.model.NIP50_SEARCH_RELAYS
import com.nostrvault.data.model.ProfileUpdateSignal
import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.relay.HavenBridge
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.serialization.json.*
import kotlin.coroutines.resume
import java.net.URL
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.locks.ReentrantLock
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.concurrent.withLock
import kotlin.math.min
import kotlin.math.pow

/**
 * Core Nostr relay management service.
 * Handles relay connections, event subscriptions, profile caching,
 * event signing/publishing, and global search.
 *
 * Port of NostrService.swift — uses StateFlow/SharedFlow instead of @Published/Combine.
 */
@Singleton
class NostrService @Inject constructor(
    private val configStore: ConfigStore,
    private val credentialStore: CredentialStore,
    private val profileRepository: ProfileRepository,
    private val eventPublisher: EventPublisher,
    private val amberSignerService: AmberSignerService,
    private val powPreferences: com.nostrvault.data.local.PowPreferences,
) {
    companion object {
        private const val TAG = "NostrService"
        private const val MAX_SEEN_IDS = 50_000
        private const val TRIM_SEEN_IDS = 40_000
        private const val MAX_EVENTS = 10_000
        private const val BUFFER_FLUSH_DELAY_MS = 300L
        private const val PROFILE_SAVE_THROTTLE_MS = 5_000L
        private const val PROFILE_FLUSH_DELAY_MS = 100L
        private const val PROFILE_UPDATE_DEBOUNCE_MS = 100L
        // A cached profile is "fresh" for this long before we'll re-fetch its metadata.
        private const val PROFILE_TTL_MS = 7L * 24 * 60 * 60 * 1000 // 7 days
        // After dispatching a metadata REQ, suppress re-fetching the same pubkey for this
        // long. This negatively-caches pubkeys with no resolvable kind-0 (and dedupes
        // in-flight fetches) so they don't re-trigger a 3-relay fetch on every note.
        private const val PROFILE_RETRY_TTL_MS = 30L * 60 * 1000 // 30 min
        // Soft cap on in-memory profiles; trimmed to TRIM_CACHED_PROFILES when exceeded.
        private const val MAX_CACHED_PROFILES = 5_000
        private const val TRIM_CACHED_PROFILES = 4_000
        // Prune the fetch-attempt map once it grows past this.
        private const val MAX_FETCH_ATTEMPTS = 10_000
        private const val FETCH_WATCHDOG_TIMEOUT_MS = 8_000L
        private const val MAX_RECONNECT_ATTEMPTS = 10
        private const val BASE_RECONNECT_DELAY_MS = 2_000L
        private const val MAX_RECONNECT_DELAY_MS = 30_000L
        private const val SEARCH_TIMEOUT_MS = 4_000L
        private const val TEMP_CLIENT_DISCONNECT_MS = 3_000L
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val json = Json { ignoreUnknownKeys = true }

    // ── Observable state ──────────────────────────────────────────────

    private val _connectionStatus = MutableStateFlow("Disconnected")
    val connectionStatus: StateFlow<String> = _connectionStatus.asStateFlow()

    private val _connectionColor = MutableStateFlow("gray")
    val connectionColor: StateFlow<String> = _connectionColor.asStateFlow()

    private val _isFetching = MutableStateFlow(false)
    val isFetching: StateFlow<Boolean> = _isFetching.asStateFlow()

    private val _profiles = MutableStateFlow<Map<String, FeedProfile>>(emptyMap())
    val profiles: StateFlow<Map<String, FeedProfile>> = _profiles.asStateFlow()

    private val _relayLists = MutableStateFlow<Map<String, List<String>>>(emptyMap())
    val relayLists: StateFlow<Map<String, List<String>>> = _relayLists.asStateFlow()

    private val _outboxRelays = MutableStateFlow<Map<String, List<String>>>(emptyMap())
    val outboxRelays: StateFlow<Map<String, List<String>>> = _outboxRelays.asStateFlow()

    private val _dmRelayLists = MutableStateFlow<Map<String, List<String>>>(emptyMap())
    val dmRelayLists: StateFlow<Map<String, List<String>>> = _dmRelayLists.asStateFlow()

    private val _serverLists = MutableStateFlow<Map<String, List<String>>>(emptyMap())
    val serverLists: StateFlow<Map<String, List<String>>> = _serverLists.asStateFlow()

    private val _profileUpdates = MutableSharedFlow<ProfileUpdateSignal>(replay = 0)
    val profileUpdates: SharedFlow<ProfileUpdateSignal> = _profileUpdates.asSharedFlow()

    /** Emitted whenever the main event list is mutated. */
    private val _eventUpdates = MutableSharedFlow<Unit>(replay = 0, extraBufferCapacity = 1)
    val eventUpdates: SharedFlow<Unit> = _eventUpdates.asSharedFlow()

    // ── Internal mutable state ────────────────────────────────────────

    var events: List<NostrEvent> = emptyList()
        private set
    var noteMedia: List<MediaItem> = emptyList()
        private set
    var lastForegroundReconnectTime: Long? = null

    /** Always resolves from current config (not cached at init time). */
    val ownerHexPubkey: String
        get() {
            val npub = configStore.config.value.ownerNpub
            return when {
                npub.isEmpty() -> ""
                npub.startsWith("npub1") -> npubToHex(npub) ?: ""
                npub.length == 64 && npub.all { it in '0'..'9' || it in 'a'..'f' } -> npub
                else -> npubToHex(npub) ?: ""
            }
        }
    val activeHexPubkey: String
        get() {
            val npub = configStore.config.value.activeAccountNpub ?: return ownerHexPubkey
            // Handle both npub and raw hex formats
            if (npub.length == 64 && npub.all { it in '0'..'9' || it in 'a'..'f' }) return npub
            return npubToHex(npub) ?: ownerHexPubkey
        }

    // ── Relay pool ────────────────────────────────────────────────────

    private val clients = ConcurrentHashMap<String, WebSocketClient>()
    private val activeSubscriptions = ConcurrentHashMap<String, String>()
    private val temporaryClients = mutableSetOf<WebSocketClient>()
    private val tempClientsLock = ReentrantLock()

    /** Limits concurrent temporary WebSocket connections to prevent OOM. */
    private val tempClientSemaphore = Semaphore(8)

    // ── Reconnection backoff ──────────────────────────────────────────

    private val reconnectAttempts = ConcurrentHashMap<String, Int>()
    private val lastReconnectTime = ConcurrentHashMap<String, Long>()
    private val relaysReconnecting = ConcurrentHashMap.newKeySet<String>()

    // ── Deduplication ─────────────────────────────────────────────────

    private val seenEventIds = LinkedHashSet<String>()
    private val seenLock = ReentrantLock()

    // ── Event batching ────────────────────────────────────────────────

    private val eventBuffer = mutableListOf<Pair<NostrEvent, List<MediaItem>>>()
    private val bufferLock = ReentrantLock()
    private var bufferFlushJob: Job? = null

    // ── Profile fetching ──────────────────────────────────────────────

    private val profileFetchQueue = mutableSetOf<String>()
    private val profileQueueLock = ReentrantLock()
    // pubkey -> epoch millis of last dispatched metadata REQ (negative/in-flight cache).
    // Guarded by profileQueueLock.
    private val profileFetchAttempts = mutableMapOf<String, Long>()
    private var profileFlushJob: Job? = null
    private var profileSaveJob: Job? = null
    private var lastProfileSaveTime = 0L

    // ── Profile update coalescing ─────────────────────────────────────

    private val pendingProfileUpdates = mutableSetOf<String>()
    private val profileUpdateLock = ReentrantLock()
    private var profileUpdateJob: Job? = null
    private var profileUpdateGeneration = 0

    // ── Fetch tracking ────────────────────────────────────────────────

    private var activeSubscriptionCount = 0
    private var fetchWatchdogJob: Job? = null

    // ── Search ────────────────────────────────────────────────────────

    private val searchClients = mutableSetOf<WebSocketClient>()
    private val searchClientsLock = ReentrantLock()

    // ── Account switch ────────────────────────────────────────────────

    private var accountSwitchJob: Job? = null

    // ══════════════════════════════════════════════════════════════════
    // Initialization
    // ══════════════════════════════════════════════════════════════════

    init {
        initialize()
    }

    fun initialize() {
        Log.d(TAG, "initialize: ownerHexPubkey=${ownerHexPubkey.take(16)}... (from ownerNpub=${configStore.config.value.ownerNpub.take(20)}...)")
        loadProfilesFromDisk()
        observeAccountSwitch()
    }

    private fun loadProfilesFromDisk() {
        scope.launch(Dispatchers.IO) {
            val loaded = profileRepository.loadProfiles()
            val relays = profileRepository.loadRelayLists()
            val outbox = profileRepository.loadOutboxRelays()
            val dmRelays = profileRepository.loadDMRelayLists()
            val servers = profileRepository.loadServerLists()
            withContext(Dispatchers.Main.immediate) {
                _profiles.value = loaded
                _relayLists.value = relays
                _outboxRelays.value = outbox
                _dmRelayLists.value = dmRelays
                _serverLists.value = servers
            }
        }
    }

    private fun observeAccountSwitch() {
        scope.launch {
            configStore.config
                .map { it.activeAccountNpub }
                .distinctUntilChanged()
                .drop(1) // Skip initial emission
                .collect { handleAccountSwitch() }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Account switching
    // ══════════════════════════════════════════════════════════════════

    fun handleAccountSwitch() {
        accountSwitchJob?.cancel()
        accountSwitchJob = scope.launch {
            // 1. Close all active relay subscriptions
            for ((url, subId) in activeSubscriptions) {
                clients[url]?.send("[\"CLOSE\",\"$subId\"]")
            }

            // 2. Disconnect all clients
            clients.values.forEach { it.disconnect() }
            clients.clear()
            activeSubscriptions.clear()
            relaysReconnecting.clear()

            // 3. Disconnect temporary clients
            tempClientsLock.withLock {
                temporaryClients.forEach { it.disconnect() }
                temporaryClients.clear()
            }

            // 4. Clear event state
            events = emptyList()
            noteMedia = emptyList()
            clearSeen()

            // 5. Flush pending event buffer
            bufferLock.withLock {
                eventBuffer.clear()
                bufferFlushJob?.cancel()
                bufferFlushJob = null
            }

            // 6. Reset fetch tracking
            _isFetching.value = false
            activeSubscriptionCount = 0
            fetchWatchdogJob?.cancel()

            // 7. Clear reconnect backoff
            reconnectAttempts.clear()
            lastReconnectTime.clear()

            // 8. Notify UI
            _eventUpdates.tryEmit(Unit)

            // 9. Force-fetch the newly-active account's profile (name/avatar) and
            //    prefetch the rest of the roster. Profile fetches use temporary
            //    relay clients, so this survives the teardown above.
            val activeHex = activeHexPubkey
            if (activeHex.isNotEmpty()) fetchMissingProfiles(listOf(activeHex), force = true)
            prefetchWhitelistedProfiles()

            // 10. Reconnect for new account
            reconnectForActiveAccount()
        }
    }

    private fun reconnectForActiveAccount() {
        // Subclasses / FeedService will drive actual relay connections.
        // This resets the connection indicators.
        _connectionStatus.value = "Connecting..."
        _connectionColor.value = "yellow"
    }

    // ══════════════════════════════════════════════════════════════════
    // Relay connection management
    // ══════════════════════════════════════════════════════════════════

    /**
     * Connect to a relay and register a message handler.
     * Returns the WebSocketClient if connection succeeds.
     */
    fun connectToRelay(
        url: String,
        onMessage: (String) -> Unit,
        onStateChange: ((WebSocketClient.ConnectionState) -> Unit)? = null,
    ): WebSocketClient? {
        val normalizedUrl = normalizeRelayUrl(url)
        clients[normalizedUrl]?.let { existing ->
            if (existing.connectionState.value == WebSocketClient.ConnectionState.CONNECTED) {
                return existing
            }
            existing.disconnect()
        }

        val client = WebSocketClient(
            url = normalizedUrl,
            scope = scope,
            trustLocalhost = isLocalUrl(normalizedUrl),
        )

        clients[normalizedUrl] = client

        scope.launch {
            client.messages.collect { message ->
                launch(Dispatchers.Default) { onMessage(message) }
            }
        }

        onStateChange?.let { handler ->
            scope.launch {
                client.connectionState.collect { state -> handler(state) }
            }
        }

        client.connect()
        return client
    }

    fun disconnectRelay(url: String) {
        val normalizedUrl = normalizeRelayUrl(url)
        clients.remove(normalizedUrl)?.disconnect()
        activeSubscriptions.remove(normalizedUrl)
    }

    fun disconnectAll() {
        clients.values.forEach { it.disconnect() }
        clients.clear()
        activeSubscriptions.clear()
        tempClientsLock.withLock {
            temporaryClients.forEach { it.disconnect() }
            temporaryClients.clear()
        }
    }

    /**
     * Reconnect to a relay with exponential backoff.
     */
    fun scheduleReconnect(url: String, onMessage: (String) -> Unit) {
        val normalizedUrl = normalizeRelayUrl(url)
        if (relaysReconnecting.contains(normalizedUrl)) return

        val attempts = reconnectAttempts.getOrDefault(normalizedUrl, 0)
        if (attempts >= MAX_RECONNECT_ATTEMPTS) {
            Log.w(TAG, "Max reconnect attempts reached for $normalizedUrl")
            return
        }

        relaysReconnecting.add(normalizedUrl)
        val delay = calculateBackoffDelay(attempts)
        reconnectAttempts[normalizedUrl] = attempts + 1

        scope.launch {
            delay(delay)
            relaysReconnecting.remove(normalizedUrl)
            connectToRelay(normalizedUrl, onMessage)
        }
    }

    private fun calculateBackoffDelay(attempts: Int): Long {
        val base = BASE_RECONNECT_DELAY_MS * 2.0.pow(attempts).toLong()
        val capped = min(base, MAX_RECONNECT_DELAY_MS)
        val jitter = (Math.random() * 2000).toLong()
        return capped + jitter
    }

    fun resetReconnectBackoff(url: String) {
        val normalizedUrl = normalizeRelayUrl(url)
        reconnectAttempts.remove(normalizedUrl)
        lastReconnectTime.remove(normalizedUrl)
    }

    // ══════════════════════════════════════════════════════════════════
    // Subscriptions (REQ / CLOSE)
    // ══════════════════════════════════════════════════════════════════

    /**
     * Send a REQ subscription on a connected relay.
     */
    fun sendSubscription(
        relayUrl: String,
        subscriptionId: String,
        filters: List<Map<String, Any>>,
    ) {
        val normalizedUrl = normalizeRelayUrl(relayUrl)
        val client = clients[normalizedUrl] ?: return

        activeSubscriptions[normalizedUrl] = subscriptionId

        val filtersJson = filters.joinToString(",") { buildFilterJson(it) }
        val req = "[\"REQ\",\"$subscriptionId\",$filtersJson]"
        client.send(req)
    }

    fun closeSubscription(relayUrl: String, subscriptionId: String) {
        val normalizedUrl = normalizeRelayUrl(relayUrl)
        clients[normalizedUrl]?.send("[\"CLOSE\",\"$subscriptionId\"]")
        activeSubscriptions.remove(normalizedUrl)
    }

    // ══════════════════════════════════════════════════════════════════
    // Event processing pipeline
    // ══════════════════════════════════════════════════════════════════

    /**
     * Process a raw relay message. Called from background dispatcher.
     * Handles EVENT, EOSE, OK, NOTICE, AUTH messages.
     */
    fun processRelayMessage(message: String, relayUrl: String) {
        try {
            val parsed = json.parseToJsonElement(message).jsonArray
            if (parsed.isEmpty()) return

            val type = parsed[0].jsonPrimitive.contentOrNull ?: return

            when (type) {
                "EVENT" -> {
                    if (parsed.size < 3) return
                    val eventObj = parsed[2].jsonObject
                    processEvent(eventObj, relayUrl)
                }
                "EOSE" -> {
                    if (parsed.size < 2) return
                    val subId = parsed[1].jsonPrimitive.contentOrNull ?: return
                    handleEOSE(subId, relayUrl)
                }
                "OK" -> {
                    // Event acceptance acknowledgment — no action needed for now
                }
                "NOTICE" -> {
                    if (parsed.size >= 2) {
                        val notice = parsed[1].jsonPrimitive.contentOrNull
                        Log.d(TAG, "NOTICE from $relayUrl: $notice")
                    }
                }
                "AUTH" -> {
                    // NIP-42 auth challenge — handled by specific services
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to parse relay message: ${e.message}")
        }
    }

    private fun processEvent(eventObj: JsonObject, relayUrl: String) {
        val id = eventObj["id"]?.jsonPrimitive?.contentOrNull ?: return
        val pubkey = eventObj["pubkey"]?.jsonPrimitive?.contentOrNull ?: return
        val kind = eventObj["kind"]?.jsonPrimitive?.intOrNull ?: return
        val content = eventObj["content"]?.jsonPrimitive?.contentOrNull ?: ""
        val createdAt = eventObj["created_at"]?.jsonPrimitive?.longOrNull ?: return
        val sig = eventObj["sig"]?.jsonPrimitive?.contentOrNull ?: ""

        val tags = eventObj["tags"]?.jsonArray?.map { tagArray ->
            tagArray.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" }
        } ?: emptyList()

        // Reject future-dated events (>60s in future)
        val nowSecs = System.currentTimeMillis() / 1000
        if (createdAt > nowSecs + 60) return

        // Process metadata and relay list events immediately (before dedup)
        when (kind) {
            0 -> {
                parseAndCacheProfile(pubkey, content)
                return
            }
            10002 -> {
                parseRelayListEvent(pubkey, tags)
                return
            }
            10050 -> {
                parseDmRelayListEvent(pubkey, tags)
                return
            }
            10063 -> {
                parseServerListEvent(pubkey, tags)
                return
            }
            10000 -> {
                parseMuteListEvent(tags)
                return
            }
        }

        // Dedup check
        if (!markSeen(id)) return

        // Extract media URLs from content
        val mediaItems = extractMediaURLs(content, pubkey, tags, createdAt)

        val event = NostrEvent(
            id = id,
            pubkey = pubkey,
            createdAt = createdAt,
            kind = kind,
            tags = tags,
            content = content,
            sig = sig,
        )

        // Buffer for batched flush
        bufferLock.withLock {
            eventBuffer.add(event to mediaItems)
        }
        scheduleBufferFlush()
    }

    private fun handleEOSE(subId: String, relayUrl: String) {
        // Close historical (one-shot) subscriptions
        if (subId.contains("-hist-")) {
            closeSubscription(relayUrl, subId)
        }

        activeSubscriptionCount--
        if (activeSubscriptionCount <= 0) {
            activeSubscriptionCount = 0
            scope.launch(Dispatchers.Main.immediate) {
                _isFetching.value = false
            }
            fetchWatchdogJob?.cancel()

            // Sort events by created_at descending
            events = events.sortedByDescending { it.createdAt }
            _eventUpdates.tryEmit(Unit)
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Event batching
    // ══════════════════════════════════════════════════════════════════

    private fun scheduleBufferFlush() {
        if (bufferFlushJob != null) return
        bufferFlushJob = scope.launch {
            delay(BUFFER_FLUSH_DELAY_MS)
            flushEventBuffer()
        }
    }

    private fun flushEventBuffer() {
        val batch = bufferLock.withLock {
            val copy = eventBuffer.toList()
            eventBuffer.clear()
            bufferFlushJob = null
            copy
        }

        if (batch.isEmpty()) return

        val newEvents = batch.map { it.first }
        val newMedia = batch.flatMap { it.second }

        events = (events + newEvents)
            .sortedByDescending { it.createdAt }
            .take(MAX_EVENTS)

        noteMedia = noteMedia + newMedia
        _eventUpdates.tryEmit(Unit)
    }

    // ══════════════════════════════════════════════════════════════════
    // Deduplication
    // ══════════════════════════════════════════════════════════════════

    fun markSeen(id: String): Boolean = seenLock.withLock {
        if (seenEventIds.contains(id)) return@withLock false
        seenEventIds.add(id)
        if (seenEventIds.size > MAX_SEEN_IDS) {
            val excess = seenEventIds.size - TRIM_SEEN_IDS
            val iter = seenEventIds.iterator()
            repeat(excess) {
                if (iter.hasNext()) {
                    iter.next()
                    iter.remove()
                }
            }
        }
        true
    }

    fun hasSeen(id: String): Boolean = seenLock.withLock {
        seenEventIds.contains(id)
    }

    private fun clearSeen() = seenLock.withLock {
        seenEventIds.clear()
    }

    // ══════════════════════════════════════════════════════════════════
    // Fetch watchdog
    // ══════════════════════════════════════════════════════════════════

    fun armFetchWatchdog() {
        fetchWatchdogJob?.cancel()
        fetchWatchdogJob = scope.launch {
            delay(FETCH_WATCHDOG_TIMEOUT_MS)
            if (_isFetching.value) {
                _isFetching.value = false
                activeSubscriptionCount = 0
                Log.w(TAG, "Fetch watchdog triggered — forcing isFetching=false")
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Profile management
    // ══════════════════════════════════════════════════════════════════

    /**
     * Queue pubkeys for batched profile metadata fetch.
     */
    fun fetchMissingProfiles(pubkeys: List<String>, force: Boolean = false) {
        val now = System.currentTimeMillis()
        val currentProfiles = _profiles.value
        val missing = profileQueueLock.withLock {
            pubkeys.filter { pk -> shouldFetchProfile(pk, currentProfiles[pk], now, force) }
                .also { profileFetchQueue.addAll(it) }
        }
        if (missing.isEmpty()) return

        scheduleProfileFlush()
    }

    /**
     * Decide whether a pubkey's metadata is worth (re-)fetching. Must be called while
     * holding [profileQueueLock] (it reads [profileFetchAttempts]).
     *
     * Skips when: a fresh cached profile exists (within [PROFILE_TTL_MS]); a legacy cached
     * profile with no timestamp exists (preserves prior behaviour, avoids a first-launch
     * refetch storm); or a metadata REQ was dispatched recently (within
     * [PROFILE_RETRY_TTL_MS]) — the latter negatively-caches unresolvable pubkeys and
     * dedupes in-flight fetches. [force] bypasses freshness/retry but still skips nothing.
     */
    private fun shouldFetchProfile(
        pubkey: String,
        cached: FeedProfile?,
        now: Long,
        force: Boolean,
    ): Boolean {
        if (force) return true
        if (cached != null) {
            // Legacy entries (fetchedAt == null) are treated as fresh; stamped entries
            // refresh once their TTL lapses.
            val fresh = cached.fetchedAt?.let { now - it < PROFILE_TTL_MS } ?: true
            if (fresh) return false
        }
        val lastAttempt = profileFetchAttempts[pubkey]
        if (lastAttempt != null && now - lastAttempt < PROFILE_RETRY_TTL_MS) return false
        return true
    }

    private fun scheduleProfileFlush() {
        if (profileFlushJob != null) return
        profileFlushJob = scope.launch {
            delay(PROFILE_FLUSH_DELAY_MS)
            flushMetadataRequests()
        }
    }

    private fun flushMetadataRequests() {
        val pubkeys = profileQueueLock.withLock {
            val batch = profileFetchQueue.toList()
            profileFetchQueue.clear()
            profileFlushJob = null
            batch
        }
        if (pubkeys.isEmpty()) return

        val blastrRelays = configStore.config.value.activeBlastrRelays
        if (blastrRelays.isEmpty()) return

        // Record the dispatch time so these pubkeys are negatively-cached for
        // PROFILE_RETRY_TTL_MS even if no kind-0 comes back (no resolvable profile, or it
        // arrives after the temp-client timeout). Prevents re-fetch churn on every note.
        val now = System.currentTimeMillis()
        profileQueueLock.withLock {
            pubkeys.forEach { profileFetchAttempts[it] = now }
            if (profileFetchAttempts.size > MAX_FETCH_ATTEMPTS) {
                profileFetchAttempts.entries
                    .removeAll { now - it.value >= PROFILE_RETRY_TTL_MS }
            }
        }

        val subId = "meta-${UUID.randomUUID().toString().take(8)}"
        val filter = buildMap<String, Any> {
            put("kinds", listOf(0))
            put("authors", pubkeys)
        }

        // Connect to a few Blastr relays in parallel for metadata (kind 0 is widely replicated)
        for (relayUrl in blastrRelays.shuffled().take(3)) {
            if (!isValidRelayUrl(relayUrl)) continue
            scope.launch(Dispatchers.IO) {
                tempClientSemaphore.withPermit {
                    val client = WebSocketClient(url = relayUrl, scope = scope)
                    tempClientsLock.withLock { temporaryClients.add(client) }

                    scope.launch {
                        client.messages.collect { msg ->
                            launch(Dispatchers.Default) {
                                processRelayMessage(msg, relayUrl)
                            }
                        }
                    }

                    client.connect()
                    val filterJson = buildFilterJson(filter)
                    client.send("[\"REQ\",\"$subId\",$filterJson]")

                    // Auto-disconnect after timeout
                    delay(TEMP_CLIENT_DISCONNECT_MS)
                    client.disconnect()
                    tempClientsLock.withLock { temporaryClients.remove(client) }
                }
            }
        }
    }

    private fun parseAndCacheProfile(pubkey: String, content: String) {
        val existingProfile = _profiles.value[pubkey]
        val result = profileRepository.parseMetadataContent(content, pubkey, existingProfile) ?: return
        val (parsed, changed) = result
        val now = System.currentTimeMillis()

        if (!changed && existingProfile != null) {
            // Content identical to cache — just reset the freshness TTL. Skip the duplicate
            // relay responses that arrive in the same fetch burst (entry already stamped)
            // to avoid redundant StateFlow emissions.
            val lastStamp = existingProfile.fetchedAt
            if (lastStamp != null && now - lastStamp < PROFILE_RETRY_TTL_MS) return
            scope.launch(Dispatchers.Main.immediate) {
                _profiles.value = _profiles.value + (pubkey to existingProfile.copy(fetchedAt = now))
            }
            return
        }

        val profile = parsed.copy(fetchedAt = now)
        scope.launch(Dispatchers.Main.immediate) {
            _profiles.value = trimProfiles(_profiles.value + (pubkey to profile))
            noteProfileUpdated(pubkey)
            saveProfilesThrottled()
        }
    }

    /**
     * Keep the in-memory profile map bounded. When it exceeds [MAX_CACHED_PROFILES],
     * retain the [TRIM_CACHED_PROFILES] freshest entries (by fetchedAt) plus the owner's
     * own profile. Disk converges to the trimmed set on the next throttled save.
     */
    private fun trimProfiles(profiles: Map<String, FeedProfile>): Map<String, FeedProfile> {
        if (profiles.size <= MAX_CACHED_PROFILES) return profiles
        val kept = profiles.entries
            .sortedByDescending { it.value.fetchedAt ?: 0L }
            .take(TRIM_CACHED_PROFILES)
            .associate { it.key to it.value }
        val owner = ownerHexPubkey
        return if (owner.isNotEmpty() && !kept.containsKey(owner) && profiles.containsKey(owner)) {
            kept + (owner to profiles.getValue(owner))
        } else {
            kept
        }
    }

    private fun parseRelayListEvent(pubkey: String, tags: List<List<String>>) {
        val (readRelays, writeRelays) = profileRepository.parseRelayListTags(tags)
        scope.launch(Dispatchers.Main.immediate) {
            if (readRelays.isNotEmpty()) {
                _relayLists.value = _relayLists.value + (pubkey to readRelays)
            }
            if (writeRelays.isNotEmpty()) {
                _outboxRelays.value = _outboxRelays.value + (pubkey to writeRelays)
            }
        }
    }

    private fun parseDmRelayListEvent(pubkey: String, tags: List<List<String>>) {
        val dmRelays = profileRepository.parseDMRelayListTags(tags)
        if (dmRelays.isNotEmpty()) {
            scope.launch(Dispatchers.Main.immediate) {
                _dmRelayLists.value = _dmRelayLists.value + (pubkey to dmRelays)
            }
        }
    }

    private fun parseServerListEvent(pubkey: String, tags: List<List<String>>) {
        val servers = profileRepository.parseServerListTags(tags)
        if (servers.isNotEmpty()) {
            scope.launch(Dispatchers.Main.immediate) {
                _serverLists.value = _serverLists.value + (pubkey to servers)
            }
        }
    }

    private fun parseMuteListEvent(tags: List<List<String>>) {
        val mutedNpubs = profileRepository.parseMuteListPTags(tags).mapNotNull { hexToNpub(it) }
        // The owner's kind-10000 mute list. Sync into the owner's per-account blocked
        // list (and the legacy flat field for backward compatibility).
        configStore.update { config ->
            val ownerKey = config.ownerNpub
            config.copy(
                blockedNpubs = mutedNpubs,
                blockedNpubsPerAccount = if (ownerKey.isNotEmpty())
                    config.blockedNpubsPerAccount + (ownerKey to mutedNpubs)
                else config.blockedNpubsPerAccount,
            )
        }
    }

    /**
     * Signal that a profile has been updated (coalesced, debounced).
     */
    fun noteProfileUpdated(pubkey: String) {
        profileUpdateLock.withLock {
            pendingProfileUpdates.add(pubkey)
        }

        profileUpdateJob?.cancel()
        profileUpdateJob = scope.launch {
            delay(PROFILE_UPDATE_DEBOUNCE_MS)
            val pubkeys = profileUpdateLock.withLock {
                val set = pendingProfileUpdates.toSet()
                pendingProfileUpdates.clear()
                set
            }
            if (pubkeys.isNotEmpty()) {
                profileUpdateGeneration++
                _profileUpdates.emit(
                    ProfileUpdateSignal(profileUpdateGeneration, pubkeys)
                )
            }
        }
    }

    fun saveProfilesThrottled() {
        val now = System.currentTimeMillis()
        if (now - lastProfileSaveTime < PROFILE_SAVE_THROTTLE_MS) return
        lastProfileSaveTime = now

        profileSaveJob?.cancel()
        profileSaveJob = scope.launch(Dispatchers.IO) {
            profileRepository.saveProfiles(_profiles.value)
            profileRepository.saveRelayLists(_relayLists.value)
            profileRepository.saveOutboxRelays(_outboxRelays.value)
            profileRepository.saveDMRelayLists(_dmRelayLists.value)
            profileRepository.saveServerLists(_serverLists.value)
        }
    }

    private fun prefetchWhitelistedProfiles() {
        // Cover the whole roster: multi-account (owner + accountNpubs) plus any
        // relay-follow whitelisted accounts, so every switchable account's
        // kind-0 (name/avatar) is fetched.
        val cfg = configStore.config.value
        val npubs = (cfg.allAccountNpubs() + (cfg.whitelistedNpubs ?: emptyList())).distinct()
        val hexes = npubs.mapNotNull { npubToHex(it) }
        if (hexes.isNotEmpty()) fetchMissingProfiles(hexes)
    }

    // ══════════════════════════════════════════════════════════════════
    // Relay list fetching
    // ══════════════════════════════════════════════════════════════════

    /**
     * Fetch relay list (kinds 10002, 10050) for a specific pubkey.
     */
    fun fetchRelayList(pubkey: String) {
        if (_relayLists.value.containsKey(pubkey) && _dmRelayLists.value.containsKey(pubkey)) {
            return
        }

        val subId = "relays-${UUID.randomUUID().toString().take(8)}"
        val filter = buildMap<String, Any> {
            put("kinds", listOf(10002, 10050))
            put("authors", listOf(pubkey))
            put("limit", 2)
        }

        val blastrRelays = configStore.config.value.activeBlastrRelays
        for (relayUrl in blastrRelays.take(3)) {
            if (!isValidRelayUrl(relayUrl)) continue
            scope.launch(Dispatchers.IO) {
                tempClientSemaphore.withPermit {
                    val client = WebSocketClient(url = relayUrl, scope = scope)
                    tempClientsLock.withLock { temporaryClients.add(client) }

                    scope.launch {
                        client.messages.collect { msg ->
                            launch(Dispatchers.Default) {
                                processRelayMessage(msg, relayUrl)
                            }
                        }
                    }

                    client.connect()
                    client.send("[\"REQ\",\"$subId\",${buildFilterJson(filter)}]")

                    delay(TEMP_CLIENT_DISCONNECT_MS)
                    client.disconnect()
                    tempClientsLock.withLock { temporaryClients.remove(client) }
                }
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Event signing
    // ══════════════════════════════════════════════════════════════════

    /**
     * Sign a Nostr event synchronously (for local key signing).
     */
    fun signEvent(
        kind: Int,
        content: String,
        tags: List<List<String>> = emptyList(),
        password: String? = null,
        forceOwner: Boolean = false,
    ): NostrEvent? {
        val finalTags = EventPublisher.appendClientTag(tags, kind)
        val secretKey = resolveSecretKey(forceOwner)
        if (secretKey == null) {
            Log.e(TAG, "signEvent: resolveSecretKey returned null (forceOwner=$forceOwner, signingMode=${configStore.config.value.activeSigningMode()}, hasOwnerHexKey=${configStore.config.value.ownerHexKey != null}, ownerNpub=${configStore.config.value.ownerNpub.take(12)})")
            return null
        }

        val pubkey = if (forceOwner) ownerHexPubkey else activeHexPubkey
        if (pubkey.isEmpty()) {
            Log.e(TAG, "signEvent: pubkey is empty (forceOwner=$forceOwner, ownerHexPubkey=${ownerHexPubkey.take(8)}, ownerNpub=${configStore.config.value.ownerNpub.take(12)})")
        }

        val eventJson = EventPublisher.buildUnsignedEvent(
            kind = kind,
            content = content,
            tags = finalTags,
            pubkey = pubkey,
        )

        val signed = EventPublisher.signWithGoBackend(eventJson, secretKey)
        if (signed == null) {
            Log.e(TAG, "signEvent: signWithGoBackend returned null (kind=$kind, bridgeLoaded=${com.nostrvault.relay.HavenBridge.isLoaded})")
            return null
        }
        return parseSignedEvent(signed)
    }

    /**
     * Sign a Nostr event asynchronously (supports NIP-46 remote signing).
     * Throws IllegalStateException with diagnostic info on failure.
     */
    suspend fun signEventAsync(
        kind: Int,
        content: String,
        tags: List<List<String>> = emptyList(),
        password: String? = null,
        forceOwner: Boolean = false,
    ): NostrEvent? = withContext(Dispatchers.IO) {
        val signingMode = configStore.config.value.activeSigningMode()
        Log.d(TAG, "signEventAsync: kind=$kind signingMode=$signingMode bridgeLoaded=${com.nostrvault.relay.HavenBridge.isLoaded}")

        when (signingMode) {
            "nip46" -> {
                val finalTags = EventPublisher.appendClientTag(tags, kind)
                val eventJson = EventPublisher.buildUnsignedEvent(
                    kind = kind,
                    content = content,
                    tags = finalTags,
                    pubkey = activeHexPubkey,
                )
                val signed = NIP46Service.signEvent(eventJson)
                    ?: throw IllegalStateException("NIP-46 remote signer failed")
                return@withContext parseSignedEvent(signed)
            }
            "amber" -> {
                val finalTags = EventPublisher.appendClientTag(tags, kind)
                val eventJson = EventPublisher.buildUnsignedEvent(
                    kind = kind,
                    content = content,
                    tags = finalTags,
                    pubkey = activeHexPubkey,
                )
                val signed = amberSignerService.signEvent(eventJson)
                    ?: throw IllegalStateException("Amber signer failed")
                return@withContext parseSignedEvent(signed)
            }
            else -> {
                // Local signing
                if (!com.nostrvault.relay.HavenBridge.isLoaded) {
                    throw IllegalStateException("Native library not loaded")
                }
                val secretKey = resolveSecretKey(forceOwner)
                    ?: throw IllegalStateException("No signing key available (ownerHexKey=${configStore.config.value.ownerHexKey != null}, ownerNpub=${configStore.config.value.ownerNpub.take(8)})")
                val finalTags = EventPublisher.appendClientTag(tags, kind)
                val pubkey = if (forceOwner) ownerHexPubkey else activeHexPubkey
                val eventJson = EventPublisher.buildUnsignedEvent(
                    kind = kind, content = content, tags = finalTags, pubkey = pubkey,
                )

                // Apply NIP-13 proof of work if enabled for this event kind
                val powDifficulty = powPreferences.difficultyForKind(kind)
                val signed = if (powDifficulty > 0) {
                    EventPublisher.mineAndSignWithGoBackend(eventJson, secretKey, powDifficulty)
                        ?: EventPublisher.signWithGoBackend(eventJson, secretKey) // fallback
                } else {
                    EventPublisher.signWithGoBackend(eventJson, secretKey)
                }
                    ?: throw IllegalStateException("Go signEvent failed (pubkey=${pubkey.take(8)}, keyLen=${secretKey.length})")
                parseSignedEvent(signed)
                    ?: throw IllegalStateException("Failed to parse signed event")
            }
        }
    }

    /**
     * Sign with NIP-13 proof of work.
     */
    fun mineAndSignEvent(
        kind: Int,
        content: String,
        tags: List<List<String>> = emptyList(),
        difficulty: Int = 0,
        maxAttempts: Int = 10_000_000,
        password: String? = null,
        forceOwner: Boolean = false,
    ): NostrEvent? {
        val finalTags = EventPublisher.appendClientTag(tags, kind)
        val secretKey = resolveSecretKey(forceOwner) ?: return null

        val eventJson = EventPublisher.buildUnsignedEvent(
            kind = kind,
            content = content,
            tags = finalTags,
            pubkey = if (forceOwner) ownerHexPubkey else activeHexPubkey,
        )

        val signed = EventPublisher.mineAndSignWithGoBackend(
            eventJson, secretKey, difficulty, maxAttempts
        ) ?: return null
        return parseSignedEvent(signed)
    }

    /** Expose owner secret key for NIP-44 self-encryption (e.g. Cashu wallet). */
    fun resolveOwnerSecretKey(): String? = resolveSecretKey(forceOwner = true)

    private fun resolveSecretKey(forceOwner: Boolean): String? {
        val config = configStore.config.value
        return if (forceOwner || config.activeAccountNpub == null) {
            // Owner key — try config hex key first, then NIP-49 decrypt, then credential store fallback
            config.ownerHexKey
                ?: config.ownerNcryptsec?.let { ncryptsec ->
                    val npub = config.ownerNpub.ifEmpty { return@let null }
                    val password = credentialStore.getKeychainPassword(npub) ?: return@let null
                    NIP49Service.decrypt(ncryptsec, password)
                }
                ?: credentialStore.getNsec(ownerHexPubkey.ifEmpty { return null })
        } else {
            // Non-owner account key: stored hex key, or nsec keyed by hex pubkey.
            val npub = config.activeAccountNpub!!
            credentialStore.getCredentialHexKey(npub)
                ?: com.nostrvault.relay.HavenBridge.decodeNpub(npub)?.let { credentialStore.getNsec(it) }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Event publishing
    // ══════════════════════════════════════════════════════════════════

    /**
     * Publish an event to local relay + smart broadcast to target relays.
     */
    fun postEvent(event: NostrEvent) {
        val eventJson = serializeEvent(event)

        // 1. Post to local relay
        scope.launch(Dispatchers.IO) {
            val localUrl = configStore.config.value.nostrURL
            if (localUrl != null) {
                val client = clients[normalizeRelayUrl(localUrl)]
                    ?: connectToRelay(localUrl, onMessage = {})
                client?.send("[\"EVENT\",$eventJson]")
            }
        }

        // 2. Smart broadcast based on event kind and target
        scope.launch(Dispatchers.IO) {
            when (event.kind) {
                0 -> broadcastRawEvent(eventJson) // Profile → Blastr
                else -> {
                    // Extract target pubkey from p-tag and send to their inbox relays
                    val targetPubkey = event.tags
                        .firstOrNull { it.size >= 2 && it[0] == "p" }
                        ?.get(1)

                    if (targetPubkey != null) {
                        val targetRelays = _relayLists.value[targetPubkey]
                        if (targetRelays != null) {
                            for (relayUrl in targetRelays.filter { !it.contains("blastr") }) {
                                fireAndForgetPublish(eventJson, relayUrl)
                            }
                        }
                    }

                    // Also broadcast to Blastr for visibility
                    broadcastRawEvent(eventJson)
                }
            }
        }
    }

    /**
     * Broadcast raw event JSON to all configured Blastr relays.
     */
    fun broadcastRawEvent(
        eventJson: String,
        onRelayResult: ((String, Boolean) -> Unit)? = null,
    ) {
        val blastrRelays = configStore.config.value.activeBlastrRelays
        for (relayUrl in blastrRelays) {
            if (!isValidRelayUrl(relayUrl)) continue
            scope.launch(Dispatchers.IO) {
                tempClientSemaphore.withPermit {
                    try {
                        val client = WebSocketClient(url = relayUrl, scope = scope)
                        tempClientsLock.withLock { temporaryClients.add(client) }

                        client.connect()
                        client.send("[\"EVENT\",$eventJson]")
                        onRelayResult?.invoke(relayUrl, true)

                        delay(300) // Allow flush
                        client.disconnect()
                        tempClientsLock.withLock { temporaryClients.remove(client) }
                    } catch (e: Exception) {
                        Log.w(TAG, "Broadcast to $relayUrl failed: ${e.message}")
                        onRelayResult?.invoke(relayUrl, false)
                    }
                }
            }
        }
    }

    private fun fireAndForgetPublish(eventJson: String, relayUrl: String) {
        if (!isValidRelayUrl(relayUrl)) return
        scope.launch(Dispatchers.IO) {
            tempClientSemaphore.withPermit {
                try {
                    val client = WebSocketClient(url = relayUrl, scope = scope)
                    tempClientsLock.withLock { temporaryClients.add(client) }
                    client.connect()
                    client.send("[\"EVENT\",$eventJson]")
                    delay(300)
                    client.disconnect()
                    tempClientsLock.withLock { temporaryClients.remove(client) }
                } catch (e: Exception) {
                    Log.w(TAG, "Fire-and-forget to $relayUrl failed: ${e.message}")
                }
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Specialized event publishing
    // ══════════════════════════════════════════════════════════════════

    fun publishMuteList(accountNpub: String, blockedNpubs: List<String>) {
        val tags = blockedNpubs.mapNotNull { npub ->
            npubToHex(npub)?.let { listOf("p", it) }
        }
        val event = signEvent(kind = 10000, content = "", tags = tags, forceOwner = true)
        event?.let { postEvent(it) }
    }

    fun publishRelayList(accountNpub: String) {
        val config = configStore.config.value
        val relays = config.inboxRelays ?: return
        val tags = relays.map { listOf("r", it) }
        val event = signEvent(kind = 10002, content = "", tags = tags, forceOwner = true)
        event?.let { postEvent(it) }
    }

    fun publishDMRelayList(dmRelays: List<String>) {
        // A kind 10050 is a PUBLIC announcement of where others should deliver
        // DMs to us. The embedded Haven relay lives on 127.0.0.1 and is never
        // reachable by anyone else, so loopback URLs must be stripped — otherwise
        // senders are told to deliver replies to an address they can't reach.
        var relays = dmRelays.filter {
            !it.contains("localhost") && !it.contains("127.0.0.1")
        }
        // Never publish an empty list — fall back to public defaults.
        if (relays.isEmpty()) {
            relays = listOf(
                "wss://relay.damus.io",
                "wss://relay.primal.net",
                "wss://nos.lol",
                "wss://relay.btcforplebs.com",
            )
        }
        val tags = relays.map { listOf("r", it) }
        val event = signEvent(kind = 10050, content = "", tags = tags, forceOwner = true)
        event?.let { postEvent(it) }
    }

    fun publishServerList() {
        val mirrors = configStore.config.value.activeBlossomMirrors
        if (mirrors.isEmpty()) return
        val tags = mirrors.map { listOf("server", it) }
        val event = signEvent(kind = 10063, content = "", tags = tags, forceOwner = true)
        event?.let { postEvent(it) }
    }

    fun deleteNote(noteId: String) {
        val tags = listOf(listOf("e", noteId))
        val event = signEvent(kind = 5, content = "", tags = tags)
        event?.let { postEvent(it) }
    }

    fun reportEvent(eventId: String, pubkey: String, reason: String, description: String? = null) {
        val tags = mutableListOf(
            listOf("e", eventId),
            listOf("p", pubkey),
            listOf("reason", reason),
        )
        val event = signEvent(kind = 1984, content = description ?: "", tags = tags)
        event?.let { postEvent(it) }
    }

    fun reportUser(pubkey: String, reason: String, description: String? = null) {
        val tags = mutableListOf(
            listOf("p", pubkey),
            listOf("reason", reason),
        )
        val event = signEvent(kind = 1984, content = description ?: "", tags = tags)
        event?.let { postEvent(it) }
    }

    // ══════════════════════════════════════════════════════════════════
    // Global search (NIP-50)
    // ══════════════════════════════════════════════════════════════════

    fun globalSearch(query: String, onResult: (GlobalSearchResults) -> Unit) {
        cancelGlobalSearch()

        val collector = GlobalSearchCollector()
        val subId = "gsearch-${UUID.randomUUID().toString().take(8)}"

        val noteFilter = buildMap<String, Any> {
            put("kinds", listOf(1))
            put("search", query)
            put("limit", 30)
        }
        val profileFilter = buildMap<String, Any> {
            put("kinds", listOf(0))
            put("search", query)
            put("limit", 20)
        }

        for (relayUrl in NIP50_SEARCH_RELAYS) {
            scope.launch(Dispatchers.IO) {
                val client = WebSocketClient(url = relayUrl, scope = scope)
                searchClientsLock.withLock { searchClients.add(client) }

                scope.launch {
                    client.messages.collect { msg ->
                        collector.ingest(msg, subId)
                    }
                }

                client.connect()
                val filtersJson = "${buildFilterJson(noteFilter)},${buildFilterJson(profileFilter)}"
                client.send("[\"REQ\",\"$subId\",$filtersJson]")
            }
        }

        // Collect results after timeout
        scope.launch {
            delay(SEARCH_TIMEOUT_MS)
            val results = collector.snapshot()

            // Merge discovered profiles into cache
            val now = System.currentTimeMillis()
            for (profile in results.profiles) {
                val current = _profiles.value
                if (!current.containsKey(profile.pubkey)) {
                    _profiles.value = _profiles.value + (profile.pubkey to profile.copy(fetchedAt = now))
                }
            }

            cancelGlobalSearch()
            onResult(results)
        }
    }

    fun cancelGlobalSearch() {
        searchClientsLock.withLock {
            searchClients.forEach { it.disconnect() }
            searchClients.clear()
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Profile notes + replies fetching
    // ══════════════════════════════════════════════════════════════════

    /**
     * Fetch kind:1 notes authored by [pubkey] from known relays.
     * Results are delivered via [onResult] callback.
     */
    fun fetchProfileNotes(pubkey: String, onResult: (List<FeedNote>) -> Unit) {
        val config = configStore.config.value
        val relayUrls = buildList {
            config.nostrURL?.let { add(it) }
            // A tapped profile's notes live on the author's outbox / public relays,
            // not just our local + inbox relays. The local relay only holds the
            // owner's notes, and config.inboxRelays can be null/empty at runtime —
            // leaving the query with nowhere to find a stranger's notes. Use the
            // fallback-backed active* accessors and mirror queryDetailRelays so
            // strangers' notes are actually found (matches iOS ProfileView).
            addAll(config.activeInboxRelays)
            addAll(config.activeFeedRelays)
            addAll(config.activeBlastrRelays)
        }.distinct().take(8)
        if (relayUrls.isEmpty()) { onResult(emptyList()); return }

        val subId = "profile-${UUID.randomUUID().toString().take(8)}"
        val collected = java.util.concurrent.ConcurrentHashMap<String, FeedNote>()

        for (relayUrl in relayUrls) {
            scope.launch(Dispatchers.IO) {
                try {
                    val client = WebSocketClient(url = relayUrl, scope = scope, trustLocalhost = relayUrl.contains("localhost") || relayUrl.contains("127.0.0.1"))
                    tempClientsLock.withLock { temporaryClients.add(client) }

                    // Guarantee the collector is registered as a SharedFlow
                    // subscriber BEFORE we connect/REQ. messages has replay=0, so any
                    // EVENT/EOSE emitted before subscription is silently dropped — the
                    // race that left the temp-client query receiving nothing.
                    val subscribed = CompletableDeferred<Unit>()
                    scope.launch {
                        client.messages
                            .onSubscription { subscribed.complete(Unit) }
                            .collect { msg ->
                            try {
                                val parsed = json.parseToJsonElement(msg).jsonArray
                                // EOSE frames are ["EOSE", subId] (size 2). A < 3
                                // guard dropped them before the EOSE handler, so the
                                // collected notes were never delivered via onResult.
                                if (parsed.size < 2) return@collect
                                val type = parsed[0].jsonPrimitive.contentOrNull ?: return@collect
                                val sid = parsed[1].jsonPrimitive.contentOrNull ?: return@collect
                                if (type == "EVENT" && sid == subId) {
                                    val ev = parsed[2].jsonObject
                                    val id = ev["id"]?.jsonPrimitive?.contentOrNull ?: return@collect
                                    val pk = ev["pubkey"]?.jsonPrimitive?.contentOrNull ?: return@collect
                                    val content = ev["content"]?.jsonPrimitive?.contentOrNull ?: ""
                                    val createdAt = ev["created_at"]?.jsonPrimitive?.longOrNull ?: 0L
                                    val kind = ev["kind"]?.jsonPrimitive?.intOrNull ?: return@collect
                                    val tags: List<List<String>> = try {
                                        ev["tags"]?.jsonArray?.map { t -> t.jsonArray.map { it.jsonPrimitive.content } } ?: emptyList()
                                    } catch (_: Exception) { emptyList() }

                                    if (kind == 1) {
                                        collected[id] = FeedNote.fromEvent(id, pk, content, tags, createdAt, kind)
                                    }
                                }
                                if (type == "EOSE" && sid == subId) {
                                    onResult(collected.values.sortedByDescending { it.createdAt })
                                }
                            } catch (_: Exception) {}
                        }
                    }

                    subscribed.await()
                    client.connect()
                    val filter = """{"kinds":[1],"authors":["$pubkey"],"limit":50}"""
                    client.send("[\"REQ\",\"$subId\",$filter]")

                    delay(TEMP_CLIENT_DISCONNECT_MS)
                    client.disconnect()
                    tempClientsLock.withLock { temporaryClients.remove(client) }
                } catch (_: Exception) {}
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Profile streaming (iOS ProfileView.fetchAuthorNotes parity)
    // ══════════════════════════════════════════════════════════════════

    /**
     * Build a [ProfileStream] for [pubkey] over the local relay + a few feed
     * relays + the user's NIP-65 relays. The caller assigns callbacks then calls
     * [ProfileStream.start], and must call [ProfileStream.close] when done.
     */
    fun profileStream(pubkey: String): ProfileStream {
        val config = configStore.config.value
        val relays = buildList {
            config.nostrURL?.let { add(it) }
            val feed = config.activeFeedRelays.ifEmpty {
                listOf("wss://relay.damus.io", "wss://relay.primal.net", "wss://nos.lol")
            }
            addAll(feed.take(3))
            // NIP-65: also query the user's own preferred relays so their notes
            // are found even when they don't post to the common public relays.
            _relayLists.value[pubkey]?.let { addAll(it.take(3)) }
        }.distinct().take(6)
        return ProfileStream(pubkey, relays)
    }

    /**
     * A persistent multi-relay subscription for one profile view. Mirrors iOS
     * ProfileView's profileClients: one combined REQ (notes + metadata + contacts
     * + followers + tagged) kept open so [loadOlder]/[loadOlderTagged] can page on
     * the same sockets. Callbacks may fire on any thread; assign them before
     * calling [start].
     */
    inner class ProfileStream(
        val pubkey: String,
        private val relayUrls: List<String>,
    ) {
        private val clients = java.util.concurrent.CopyOnWriteArrayList<WebSocketClient>()
        private val jobs = java.util.concurrent.CopyOnWriteArrayList<Job>()
        private val ourHexKeys: Set<String> =
            setOfNotNull(configStore.activeAccountHexPubkey.value.takeIf { it.isNotEmpty() })
        private val initialSubId = "profile-${UUID.randomUUID().toString().take(6)}"

        /** Note authored by [pubkey] (kinds 1/6/30023). */
        var onNote: ((FeedNote) -> Unit)? = null
        /** Note by someone else that p-tags [pubkey] (Tagged tab). */
        var onTagged: ((FeedNote) -> Unit)? = null
        /** [pubkey]'s own contact list: (followingCount, followsMe). */
        var onContacts: ((Int, Boolean) -> Unit)? = null
        /** A pubkey whose contact list includes [pubkey] (a follower). */
        var onFollower: ((String) -> Unit)? = null
        /** EOSE subId — prefix is "profile-" (initial), "older-", or "older-tagged-". */
        var onEose: ((String) -> Unit)? = null

        fun start() {
            for (relayUrl in relayUrls) {
                val client = WebSocketClient(url = relayUrl, scope = scope, trustLocalhost = isLocalUrl(relayUrl))
                clients.add(client)
                tempClientsLock.withLock { temporaryClients.add(client) }

                // Subscribe to messages BEFORE connecting (replay=0 SharedFlow).
                val subscribed = CompletableDeferred<Unit>()
                jobs.add(scope.launch {
                    client.messages
                        .onSubscription { subscribed.complete(Unit) }
                        .collect { msg -> handleMessage(msg) }
                })
                // (Re)send the combined REQ on every CONNECTED transition.
                jobs.add(scope.launch {
                    client.connectionState.collect { state ->
                        if (state == WebSocketClient.ConnectionState.CONNECTED) {
                            client.send(buildInitialReq())
                        }
                    }
                })
                jobs.add(scope.launch {
                    subscribed.await()
                    client.connect()
                })
            }
        }

        private fun buildInitialReq(): String {
            val notes = """{"kinds":[1,6,30023],"authors":["$pubkey"],"limit":50}"""
            val meta = """{"kinds":[0],"authors":["$pubkey"],"limit":1}"""
            val contacts = """{"kinds":[3],"authors":["$pubkey"],"limit":1}"""
            val followers = """{"kinds":[3],"#p":["$pubkey"],"limit":100}"""
            val tagged = """{"kinds":[1,6,30023],"#p":["$pubkey"],"limit":50}"""
            return "[\"REQ\",\"$initialSubId\",$notes,$meta,$contacts,$followers,$tagged]"
        }

        fun loadOlder(until: Long) {
            val subId = "older-${UUID.randomUUID().toString().take(6)}"
            val filter = """{"kinds":[1,6,30023],"authors":["$pubkey"],"until":$until,"limit":50}"""
            clients.forEach { it.send("[\"REQ\",\"$subId\",$filter]") }
        }

        fun loadOlderTagged(until: Long) {
            val subId = "older-tagged-${UUID.randomUUID().toString().take(6)}"
            val filter = """{"kinds":[1,6,30023],"#p":["$pubkey"],"until":$until,"limit":50}"""
            clients.forEach { it.send("[\"REQ\",\"$subId\",$filter]") }
        }

        fun close() {
            jobs.forEach { it.cancel() }
            jobs.clear()
            clients.forEach { c ->
                c.disconnect()
                tempClientsLock.withLock { temporaryClients.remove(c) }
            }
            clients.clear()
        }

        private fun handleMessage(msg: String) {
            try {
                val parsed = json.parseToJsonElement(msg).jsonArray
                if (parsed.size < 2) return
                val type = parsed[0].jsonPrimitive.contentOrNull ?: return
                val sid = parsed[1].jsonPrimitive.contentOrNull ?: return
                if (type == "EOSE") { onEose?.invoke(sid); return }
                if (type != "EVENT" || parsed.size < 3) return
                val ev = parsed[2].jsonObject
                val id = ev["id"]?.jsonPrimitive?.contentOrNull ?: return
                val evPubkey = ev["pubkey"]?.jsonPrimitive?.contentOrNull ?: return
                val content = ev["content"]?.jsonPrimitive?.contentOrNull ?: ""
                val createdAt = ev["created_at"]?.jsonPrimitive?.longOrNull ?: 0L
                val kind = ev["kind"]?.jsonPrimitive?.intOrNull ?: return
                val tags: List<List<String>> = try {
                    ev["tags"]?.jsonArray?.map { t -> t.jsonArray.map { it.jsonPrimitive.content } } ?: emptyList()
                } catch (_: Exception) { emptyList() }

                when {
                    kind == 0 && evPubkey == pubkey -> parseAndCacheProfile(pubkey, content)
                    kind == 3 && evPubkey == pubkey -> {
                        val pTags = tags.filter { it.size >= 2 && it[0] == "p" }
                        val following = pTags.map { it[1] }.filter { it != pubkey }.distinct().size
                        val followsMe = ourHexKeys.isNotEmpty() && pTags.any { ourHexKeys.contains(it[1]) }
                        onContacts?.invoke(following, followsMe)
                    }
                    kind == 3 && evPubkey != pubkey -> onFollower?.invoke(evPubkey)
                    kind == 1 || kind == 6 || kind == 30023 -> {
                        if (evPubkey == pubkey) {
                            onNote?.invoke(FeedNote.fromEvent(id, evPubkey, content, tags, createdAt, kind))
                        } else if (tags.any { it.size >= 2 && it[0] == "p" && it[1] == pubkey }) {
                            onTagged?.invoke(FeedNote.fromEvent(id, evPubkey, content, tags, createdAt, kind))
                        }
                    }
                }
            } catch (_: Exception) {}
        }
    }

    /**
     * Fetch the owner's media-bearing notes from the local relay (and inbox relays).
     *
     * Queries kinds 1 (text notes), 1063 (NIP-94 file metadata) and 30023
     * (long-form) authored by [pubkey]. Returns [FeedNote]s with their
     * media URLs already extracted (regex + imeta) by [FeedNote.fromEvent].
     *
     * Used by the media gallery to surface media referenced in the user's own
     * notes that may not exist as a local Blossom blob — iOS parity.
     */
    suspend fun fetchOwnerMediaNotes(pubkey: String): List<FeedNote> = suspendCancellableCoroutine { cont ->
        val config = configStore.config.value
        val relayUrls = buildList {
            config.nostrURL?.let { add(it) }
            config.inboxRelays?.let { addAll(it) }
        }.distinct().take(5)
        if (relayUrls.isEmpty()) { cont.resume(emptyList()); return@suspendCancellableCoroutine }

        val subId = "ownermedia-${UUID.randomUUID().toString().take(8)}"
        val collected = java.util.concurrent.ConcurrentHashMap<String, FeedNote>()
        val resumed = java.util.concurrent.atomic.AtomicBoolean(false)

        fun finish() {
            if (resumed.compareAndSet(false, true)) {
                cont.resume(collected.values.sortedByDescending { it.createdAt })
            }
        }

        for (relayUrl in relayUrls) {
            scope.launch(Dispatchers.IO) {
                try {
                    val client = WebSocketClient(url = relayUrl, scope = scope, trustLocalhost = relayUrl.contains("localhost") || relayUrl.contains("127.0.0.1"))
                    tempClientsLock.withLock { temporaryClients.add(client) }

                    scope.launch {
                        client.messages.collect { msg ->
                            try {
                                val parsed = json.parseToJsonElement(msg).jsonArray
                                if (parsed.size < 2) return@collect
                                val type = parsed[0].jsonPrimitive.contentOrNull ?: return@collect
                                val sid = parsed[1].jsonPrimitive.contentOrNull ?: return@collect
                                if (sid != subId) return@collect
                                if (type == "EVENT" && parsed.size >= 3) {
                                    val ev = parsed[2].jsonObject
                                    val id = ev["id"]?.jsonPrimitive?.contentOrNull ?: return@collect
                                    val pk = ev["pubkey"]?.jsonPrimitive?.contentOrNull ?: return@collect
                                    val content = ev["content"]?.jsonPrimitive?.contentOrNull ?: ""
                                    val createdAt = ev["created_at"]?.jsonPrimitive?.longOrNull ?: 0L
                                    val kind = ev["kind"]?.jsonPrimitive?.intOrNull ?: return@collect
                                    val tags: List<List<String>> = try {
                                        ev["tags"]?.jsonArray?.map { t -> t.jsonArray.map { it.jsonPrimitive.content } } ?: emptyList()
                                    } catch (_: Exception) { emptyList() }
                                    collected[id] = FeedNote.fromEvent(id, pk, content, tags, createdAt, kind)
                                } else if (type == "EOSE") {
                                    finish()
                                }
                            } catch (_: Exception) {}
                        }
                    }

                    client.connect()
                    val filter = """{"kinds":[1,1063,30023],"authors":["$pubkey"],"limit":500}"""
                    client.send("[\"REQ\",\"$subId\",$filter]")

                    delay(TEMP_CLIENT_DISCONNECT_MS)
                    client.disconnect()
                    tempClientsLock.withLock { temporaryClients.remove(client) }
                    finish()
                } catch (_: Exception) {
                    finish()
                }
            }
        }
    }

    /**
     * Fetch a whole thread for the note-detail view. Queries the entire subtree
     * by NIP-10 thread [rootId] (so siblings and the wider thread appear when a
     * mid-thread reply is opened, not just direct replies to the opened note),
     * the [focusedId]'s own direct replies, and fetches the root plus any
     * [ancestorIds] by id so missing parents are filled in from the network.
     * Mirrors iOS NoteDetailView (fetchReplies by root + fetchParents by ids).
     */
    fun fetchThread(
        rootId: String,
        focusedId: String,
        ancestorIds: List<String>,
        onRawEvent: ((String, String) -> Unit)? = null,
        onResult: (List<FeedNote>) -> Unit,
    ) {
        fun jsonArr(values: List<String>) =
            values.distinct().joinToString(",") { "\"$it\"" }
        // #e by root + focused note + all ancestors so legacy replies that only
        // tag their direct parent (not the thread root) are still fetched.
        val eIds = (listOf(rootId, focusedId) + ancestorIds).distinct()
        val eFilter = """{"kinds":[1],"#e":[${jsonArr(eIds)}],"limit":200}"""
        // Root note itself + ancestors are not replies, so fetch by id.
        val idValues = (listOf(rootId) + ancestorIds).distinct()
        val idFilter = """{"kinds":[1],"ids":[${jsonArr(idValues)}]}"""
        queryDetailRelays(listOf(eFilter, idFilter), onRawEvent, onResult)
    }

    /**
     * Fetch a single kind-1 note by id from the detail relay set. Used as a
     * network fallback when the note-detail view is opened for a note that
     * is not in the in-memory feed cache (mirrors iOS NoteDetailViewWrapper).
     * [onResult] is invoked exactly once: with the note as soon as any relay
     * returns it, or with null after all relays go quiet.
     */
    fun fetchNoteById(
        id: String,
        onRawEvent: ((String, String) -> Unit)? = null,
        onResult: (FeedNote?) -> Unit,
    ) {
        val delivered = java.util.concurrent.atomic.AtomicBoolean(false)
        queryDetailRelays(listOf("""{"kinds":[1],"ids":["$id"]}"""), onRawEvent) { notes ->
            val match = notes.firstOrNull { it.id == id }
            if (match != null && delivered.compareAndSet(false, true)) onResult(match)
        }
        scope.launch {
            delay(TEMP_CLIENT_DISCONNECT_MS + 1000)
            if (delivered.compareAndSet(false, true)) onResult(null)
        }
    }

    /**
     * Fetch replies that directly tag any of [noteIds]. Called when the
     * thread view refocuses on a different note, to pull in sub-replies from
     * clients that tag only their parent and not the thread root (mirrors
     * iOS fetchRepliesForNote). Passing the focused note plus its known
     * children resolves legacy reply chains one level deeper per refocus.
     * [onResult] may fire once per relay EOSE with the cumulative set;
     * callers must merge idempotently.
     */
    fun fetchRepliesFor(
        noteIds: List<String>,
        onRawEvent: ((String, String) -> Unit)? = null,
        onResult: (List<FeedNote>) -> Unit,
    ) {
        if (noteIds.isEmpty()) { onResult(emptyList()); return }
        val idArr = noteIds.distinct().joinToString(",") { "\"$it\"" }
        queryDetailRelays(
            listOf("""{"kinds":[1],"#e":[$idArr],"limit":150}"""),
            onRawEvent,
            onResult,
        )
    }

    /**
     * Shared one-shot query for the note-detail view: temporary clients to
     * the detail relay set (local + inbox + feed/blastr, public fallback),
     * collecting kind-1 events. [onEose] fires on every relay's EOSE with
     * the cumulative sorted list, so callers must merge idempotently.
     * [onRawEvent] receives each raw event JSON (id, json) for raw-event
     * caching (broadcast needs the exact signed JSON).
     */
    private fun queryDetailRelays(
        filters: List<String>,
        onRawEvent: ((String, String) -> Unit)? = null,
        onEose: (List<FeedNote>) -> Unit,
    ) {
        val config = configStore.config.value
        val relayUrls = buildList {
            config.nostrURL?.let { add(it) }
            config.inboxRelays?.let { addAll(it) }
            // Replies from other users propagate to feed/blastr relays, not just
            // the local + inbox relays. Mirror iOS (NoteDetailView) which queries
            // external feed relays so strangers' replies are actually found.
            addAll(config.activeFeedRelays)
            addAll(config.activeBlastrRelays)
            // Public fallback when no external relays are configured.
            if (config.activeFeedRelays.isEmpty() &&
                config.activeBlastrRelays.isEmpty() &&
                config.inboxRelays.isNullOrEmpty()) {
                add("wss://relay.damus.io")
                add("wss://relay.primal.net")
            }
        }.distinct().take(8)
        if (relayUrls.isEmpty()) { onEose(emptyList()); return }

        val subId = "replies-${UUID.randomUUID().toString().take(8)}"
        val collected = java.util.concurrent.ConcurrentHashMap<String, FeedNote>()

        for (relayUrl in relayUrls) {
            scope.launch(Dispatchers.IO) {
                try {
                    val client = WebSocketClient(url = relayUrl, scope = scope, trustLocalhost = relayUrl.contains("localhost") || relayUrl.contains("127.0.0.1"))
                    tempClientsLock.withLock { temporaryClients.add(client) }

                    scope.launch {
                        client.messages.collect { msg ->
                            try {
                                val parsed = json.parseToJsonElement(msg).jsonArray
                                // EOSE is ["EOSE", subId] (size 2); a < 3 guard dropped
                                // it so onEose never fired and replies/thread results
                                // were never delivered. Same bug as fetchProfileNotes.
                                if (parsed.size < 2) return@collect
                                val type = parsed[0].jsonPrimitive.contentOrNull ?: return@collect
                                val sid = parsed[1].jsonPrimitive.contentOrNull ?: return@collect
                                if (type == "EVENT" && sid == subId) {
                                    val ev = parsed[2].jsonObject
                                    val id = ev["id"]?.jsonPrimitive?.contentOrNull ?: return@collect
                                    val pk = ev["pubkey"]?.jsonPrimitive?.contentOrNull ?: return@collect
                                    val content = ev["content"]?.jsonPrimitive?.contentOrNull ?: ""
                                    val createdAt = ev["created_at"]?.jsonPrimitive?.longOrNull ?: 0L
                                    val kind = ev["kind"]?.jsonPrimitive?.intOrNull ?: return@collect
                                    val tags: List<List<String>> = try {
                                        ev["tags"]?.jsonArray?.map { t -> t.jsonArray.map { it.jsonPrimitive.content } } ?: emptyList()
                                    } catch (_: Exception) { emptyList() }

                                    if (kind == 1) {
                                        collected[id] = FeedNote.fromEvent(id, pk, content, tags, createdAt, kind)
                                        onRawEvent?.invoke(id, ev.toString())
                                    }
                                }
                                if (type == "EOSE" && sid == subId) {
                                    onEose(collected.values.sortedBy { it.createdAt })
                                }
                            } catch (_: Exception) {}
                        }
                    }

                    client.connect()
                    client.send("[\"REQ\",\"$subId\",${filters.joinToString(",")}]")

                    delay(TEMP_CLIENT_DISCONNECT_MS)
                    client.disconnect()
                    tempClientsLock.withLock { temporaryClients.remove(client) }
                } catch (_: Exception) {}
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Fetch notes by ID
    // ══════════════════════════════════════════════════════════════════

    fun fetchNotesByIds(ids: List<String>, relayUrls: List<String>) {
        val subId = "ids-${UUID.randomUUID().toString().take(8)}"
        val filter = buildMap<String, Any> {
            put("ids", ids)
        }

        for (relayUrl in relayUrls) {
            scope.launch(Dispatchers.IO) {
                val client = WebSocketClient(url = relayUrl, scope = scope)
                tempClientsLock.withLock { temporaryClients.add(client) }

                scope.launch {
                    client.messages.collect { msg ->
                        launch(Dispatchers.Default) {
                            processRelayMessage(msg, relayUrl)
                        }
                    }
                }

                client.connect()
                client.send("[\"REQ\",\"$subId\",${buildFilterJson(filter)}]")

                delay(TEMP_CLIENT_DISCONNECT_MS)
                client.disconnect()
                tempClientsLock.withLock { temporaryClients.remove(client) }
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Fetch zap receipts
    // ══════════════════════════════════════════════════════════════════

    fun fetchZapReceipts(relayUrls: List<String>, limit: Int = 1000) {
        val subId = "zaps-${UUID.randomUUID().toString().take(8)}"
        val filter = buildFilterJson(buildMap<String, Any> {
            put("kinds", listOf(9735))
            put("limit", limit)
        })

        for (relayUrl in relayUrls) {
            scope.launch(Dispatchers.IO) {
                val client = WebSocketClient(url = relayUrl, scope = scope)
                tempClientsLock.withLock { temporaryClients.add(client) }

                scope.launch {
                    client.messages.collect { msg ->
                        launch(Dispatchers.Default) {
                            processRelayMessage(msg, relayUrl)
                        }
                    }
                }

                client.connect()
                client.send("[\"REQ\",\"$subId\",$filter]")

                delay(TEMP_CLIENT_DISCONNECT_MS)
                client.disconnect()
                tempClientsLock.withLock { temporaryClients.remove(client) }
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Connection status
    // ══════════════════════════════════════════════════════════════════

    fun updateConnectionStatus() {
        val connectedCount = clients.values.count {
            it.connectionState.value == WebSocketClient.ConnectionState.CONNECTED
        }
        val totalCount = clients.size

        when {
            connectedCount == 0 && totalCount == 0 -> {
                _connectionStatus.value = "Disconnected"
                _connectionColor.value = "gray"
            }
            connectedCount == 0 -> {
                _connectionStatus.value = "Connecting..."
                _connectionColor.value = "yellow"
            }
            connectedCount < totalCount -> {
                _connectionStatus.value = "Connected ($connectedCount/$totalCount)"
                _connectionColor.value = "yellow"
            }
            else -> {
                _connectionStatus.value = "Connected"
                _connectionColor.value = "green"
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Lifecycle
    // ══════════════════════════════════════════════════════════════════

    fun enterBackground() {
        profileSaveJob?.cancel()
        saveProfilesThrottled()
    }

    fun enterForeground() {
        // Resume profile timer if needed
    }

    fun resetConnections() {
        disconnectAll()
        fetchWatchdogJob?.cancel()
        bufferFlushJob?.cancel()
        profileFlushJob?.cancel()
        profileSaveJob?.cancel()
        profileUpdateJob?.cancel()
        _connectionStatus.value = "Disconnected"
        _connectionColor.value = "gray"
    }

    fun injectEvent(event: NostrEvent) {
        if (!markSeen(event.id)) return
        val mediaItems = extractMediaURLs(event.content, event.pubkey, event.tags, event.createdAt)
        bufferLock.withLock {
            eventBuffer.add(event to mediaItems)
        }
        scheduleBufferFlush()
    }

    // ══════════════════════════════════════════════════════════════════
    // Utilities
    // ══════════════════════════════════════════════════════════════════

    fun extractMediaURLs(content: String, pubkey: String, tags: List<List<String>>, createdAt: Long = 0L): List<MediaItem> {
        val urls = mutableListOf<MediaItem>()
        val urlRegex = Regex("""https?://\S+\.(jpg|jpeg|png|gif|webp|mp4|mov|webm|mp3|wav|ogg)""", RegexOption.IGNORE_CASE)
        for (match in urlRegex.findAll(content)) {
            val urlStr = match.value
            val ext = urlStr.substringAfterLast('.').lowercase()
            val mediaType = when (ext) {
                "jpg", "jpeg", "png", "gif", "webp" -> MediaType.IMAGE
                "mp4", "mov", "webm" -> MediaType.VIDEO
                "mp3", "wav", "ogg" -> MediaType.AUDIO
                else -> MediaType.UNKNOWN
            }
            urls.add(
                MediaItem(
                    url = urlStr,
                    type = mediaType,
                    pubkey = pubkey,
                    createdAt = createdAt,
                )
            )
        }
        // Also extract from tags (kind 1063 file metadata)
        for (tag in tags) {
            if (tag.size >= 2 && tag[0] == "url") {
                urls.add(
                    MediaItem(
                        url = tag[1],
                        type = MediaType.UNKNOWN,
                        pubkey = pubkey,
                        createdAt = createdAt,
                    )
                )
            }
        }
        return urls
    }

    private fun normalizeRelayUrl(url: String): String {
        return url.trimEnd('/')
    }

    private fun isLocalUrl(url: String): Boolean {
        return url.contains("localhost") || url.contains("127.0.0.1")
    }

    private fun isValidRelayUrl(url: String): Boolean {
        return url.startsWith("wss://") && !url.contains(' ')
    }

    private fun buildFilterJson(filter: Map<String, Any>): String {
        val entries = filter.entries.joinToString(",") { (key, value) ->
            when (value) {
                is String -> "\"$key\":\"$value\""
                is Int -> "\"$key\":$value"
                is Long -> "\"$key\":$value"
                is List<*> -> {
                    val items = value.joinToString(",") { item ->
                        when (item) {
                            is String -> "\"$item\""
                            is Int -> "$item"
                            is Long -> "$item"
                            else -> "\"$item\""
                        }
                    }
                    "\"$key\":[$items]"
                }
                else -> "\"$key\":\"$value\""
            }
        }
        return "{$entries}"
    }

    private fun serializeEvent(event: NostrEvent): String {
        val tagsJson = event.tags.joinToString(",") { tag ->
            "[${tag.joinToString(",") { "\"$it\"" }}]"
        }
        return buildString {
            append("{")
            append("\"id\":\"${event.id}\",")
            append("\"pubkey\":\"${event.pubkey}\",")
            append("\"created_at\":${event.createdAt},")
            append("\"kind\":${event.kind},")
            append("\"tags\":[$tagsJson],")
            append("\"content\":\"${event.content.replace("\"", "\\\"").replace("\n", "\\n")}\",")
            append("\"sig\":\"${event.sig}\"")
            append("}")
        }
    }

    private fun parseSignedEvent(json: String): NostrEvent? {
        return try {
            val obj = this.json.parseToJsonElement(json).jsonObject
            NostrEvent(
                id = obj["id"]?.jsonPrimitive?.contentOrNull ?: return null,
                pubkey = obj["pubkey"]?.jsonPrimitive?.contentOrNull ?: return null,
                createdAt = obj["created_at"]?.jsonPrimitive?.longOrNull ?: return null,
                kind = obj["kind"]?.jsonPrimitive?.intOrNull ?: return null,
                tags = obj["tags"]?.jsonArray?.map { tagArr ->
                    tagArr.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" }
                } ?: emptyList(),
                content = obj["content"]?.jsonPrimitive?.contentOrNull ?: "",
                sig = obj["sig"]?.jsonPrimitive?.contentOrNull ?: return null,
            )
        } catch (e: Exception) {
            Log.w(TAG, "Failed to parse signed event: ${e.message}")
            null
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Bech32 helpers (delegate to Go backend)
    // ══════════════════════════════════════════════════════════════════

    fun npubToHex(npub: String): String? {
        if (!npub.startsWith("npub1")) return null
        return try {
            HavenBridge.decodeNpub(npub)
        } catch (e: Exception) {
            null
        }
    }

    fun hexToNpub(hex: String): String? {
        return try {
            HavenBridge.encodeNpub(hex)
        } catch (e: Exception) {
            null
        }
    }
}

// ══════════════════════════════════════════════════════════════════
// Data types
// ══════════════════════════════════════════════════════════════════

@kotlinx.serialization.Serializable
data class NostrEvent(
    val id: String,
    val pubkey: String,
    val createdAt: Long,
    val kind: Int,
    val tags: List<List<String>>,
    val content: String,
    val sig: String,
) {
    val createdAtDate: Long get() = createdAt * 1000 // Convert to millis
}

data class MediaItem(
    val url: String,
    val type: MediaType,
    val pubkey: String? = null,
    val tags: List<List<String>>? = null,
    val mimeType: String? = null,
    val createdAt: Long = 0L,
) {
    val isAnimatedGIF: Boolean
        get() = url.lowercase().endsWith(".gif")
}

enum class MediaType(val value: String) {
    IMAGE("image"),
    VIDEO("video"),
    AUDIO("audio"),
    UNKNOWN("unknown"),
}
