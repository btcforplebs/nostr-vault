package com.nostrvault.service

import android.util.Log
import com.nostrvault.BuildConfig
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.CredentialStore
import com.nostrvault.data.local.ProfileRepository
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.NIP10Thread
import com.nostrvault.data.model.NIP88Poll
import com.nostrvault.data.model.PostingAccount
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.GlobalSearchResults
import com.nostrvault.data.model.SearchTermMatcher
import com.nostrvault.data.model.ProfileUpdateSignal
import com.nostrvault.data.remote.LookupSocketPool
import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.fips.FipsMediaRouter
import com.nostrvault.relay.DMInbox
import com.nostrvault.relay.HavenBridge
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.serialization.json.*
import java.net.URL
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.locks.ReentrantLock
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.concurrent.withLock
import kotlin.math.min

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
    private val lookupPool: LookupSocketPool,
    private val homeVault: com.nostrvault.fips.HomeVaultSender,
) {
    companion object {
        /** Kinds whose newest event replaces cached state; see [acceptReplaceable]. */
        private val REPLACEABLE_STATE_KINDS = setOf(0, 10000, 10002, 10050, 10063)

        /**
         * A loopback address means "this machine". Advertising one, or
         * publishing someone else's DM to one, sends the event to the *sender's*
         * own relay — the write succeeds, nothing errors, and the recipient
         * never sees it.
         */
        fun isLoopbackRelay(url: String): Boolean {
            val u = url.lowercase()
            return u.contains("127.0.0.1") || u.contains("localhost") ||
                u.contains("[::1]") || u.contains("0.0.0.0")
        }

        private const val TAG = "NostrService"
        private const val MAX_SEEN_IDS = 50_000
        private const val TRIM_SEEN_IDS = 40_000
        private const val MAX_EVENTS = 10_000
        private const val BUFFER_FLUSH_DELAY_MS = 300L
        private const val PROFILE_SAVE_THROTTLE_MS = 5_000L
        private const val PROFILE_FLUSH_DELAY_MS = 100L
        private const val PROFILE_EMIT_DEBOUNCE_MS = 200L
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
        private const val TEMP_CLIENT_DISCONNECT_MS = 3_000L

        /**
         * The number in a NIP-45 `["COUNT", subId, {"count": n}]` reply; relays
         * send it as an integer, a float or a string. Null for anything else.
         */
        internal fun countFrom(msg: String): Int? = try {
            val arr = Json.parseToJsonElement(msg).jsonArray
            if (arr.size < 3 || arr[0].jsonPrimitive.contentOrNull != "COUNT") null
            else arr[2].jsonObject["count"]?.jsonPrimitive?.contentOrNull
                ?.toDoubleOrNull()?.takeIf { it >= 0 }?.toInt()
        } catch (_: Exception) {
            null
        }
        // Profile relays plus Blastr, up to this many. Kind 0 coverage varies
        // wildly: relay.primal.net returns few profiles for an authors filter,
        // and a relay that is down or blocked returns none, so a short list
        // could leave the whole feed nameless.
        private const val METADATA_POOL_SIZE = 10
        // Asked for names/avatars ahead of the Blastr relays. On 2026-10-01,
        // for 300 recent posters, the default Blastr set (nos.lol and
        // nostr.mom unreachable, primal ~11%) had 115 profiles; adding these
        // reached 193. Re-measure with `.scratch/profprobe/probe.py` in the
        // Buzz nest before changing it.
        private val PROFILE_RELAYS = listOf(
            "wss://offchain.pub",
            "wss://relay.damus.io",
            "wss://user.kindpag.es",
            "wss://purplepag.es",
        )
        private const val METADATA_IDLE_TIMEOUT_MS = 60_000L
        private const val METADATA_SUB_ID = "meta-pool"
        // How long a dispatched pubkey stays in the pool's filter waiting for
        // its kind 0, and the most authors one REQ carries.
        private const val METADATA_PENDING_WINDOW_MS = 60_000L
        private const val METADATA_MAX_AUTHORS = 500
        // Authors per kind-10002 REQ in fetchRelayLists, and how long each waits.
        private const val RELAY_LIST_CHUNK = 200
        private const val RELAY_LIST_TIMEOUT_MS = 8_000L
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
    /**
     * The one active-account value, kept by [ConfigStore]. Empty when the
     * active account can't be decoded, so nothing signs as someone else; the
     * owner only when no other account is active.
     */
    val activeHexPubkey: String
        get() = configStore.activeAccountHexPubkey.value.ifEmpty {
            if (configStore.config.value.activeAccountNpub.isNullOrBlank()) ownerHexPubkey else ""
        }

    // ── Relay pool ────────────────────────────────────────────────────

    private val clients = ConcurrentHashMap<String, WebSocketClient>()
    private val activeSubscriptions = ConcurrentHashMap<String, String>()
    private val temporaryClients = mutableSetOf<WebSocketClient>()
    private val tempClientsLock = ReentrantLock()

    /** Limits concurrent temporary WebSocket connections to prevent OOM. */
    private val tempClientSemaphore = Semaphore(8)

    // ── Warm metadata (kind-0) connection pool ────────────────────────
    // A few reused, long-lived connections to Blastr relays for profile fetches.
    // Replaces opening 3 fresh sockets per flush (the handshake churn rate-limited
    // us — 429 — so profiles/names/pics stopped loading). Guarded by metadataPoolLock.
    private val metadataClients = HashMap<String, WebSocketClient>()
    private val metadataPoolLock = ReentrantLock()
    private var metadataIdleJob: Job? = null
    @Volatile private var lastMetadataFilterJson: String = ""

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

    // ── Profile-map emission batching ─────────────────────────────────
    // Incoming kind-0 profiles are staged here and merged into _profiles in ONE
    // map rebuild + ONE emission per debounce window, off the main thread. Doing
    // it per-profile copied the entire (≤5,000-entry) map and recomposed every
    // collector on each arrival — a main-thread allocation/recomposition storm
    // while profiles stream in during feed load. All guarded by profileEmitLock.
    private val pendingProfiles = HashMap<String, FeedProfile>()
    private val pendingProfileNotify = HashSet<String>()
    private var profileEmitJob: Job? = null
    private val profileEmitLock = ReentrantLock()

    // ── Profile update coalescing ─────────────────────────────────────

    private val pendingProfileUpdates = mutableSetOf<String>()
    private val profileUpdateLock = ReentrantLock()
    private var profileUpdateJob: Job? = null
    private var profileUpdateGeneration = 0

    // ── Fetch tracking ────────────────────────────────────────────────

    private var activeSubscriptionCount = 0
    private var fetchWatchdogJob: Job? = null

    // ── Account switch ────────────────────────────────────────────────

    private var accountSwitchJob: Job? = null

    // ══════════════════════════════════════════════════════════════════
    // Initialization
    // ══════════════════════════════════════════════════════════════════

    init {
        initialize()
        FipsMediaRouter.serverLists = { _serverLists.value }
        FipsMediaRouter.requestServerList = { fetchServerList(it) }
        homeVault.ownerHex = { ownerHexPubkey }
        homeVault.ownerIsActive = { ownerHexPubkey.isNotEmpty() && activeHexPubkey == ownerHexPubkey }
        homeVault.signerIsLocal = {
            SignerRouting.route(configStore.config.value, true, ownerHexPubkey, activeHexPubkey) is SignerRoute.Local
        }
        homeVault.ownerServerList = { _serverLists.value[ownerHexPubkey] }
        homeVault.signer = { kind, content, tags ->
            signEventAsync(kind = kind, content = content, tags = tags, forceOwner = true)?.let { serializeEvent(it) }
        }
    }

    fun initialize() {
        if (BuildConfig.DEBUG) Log.d(TAG, "initialize: ownerHexPubkey=${ownerHexPubkey.take(16)}... (from ownerNpub=${configStore.config.value.ownerNpub.take(20)}...)")
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
            configStore.accountSwitches.collect { handleAccountSwitch() }
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
            closeMetadataPool()

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

        // Collected on Default so a message does not hop through Main on its way there.
        scope.launch(Dispatchers.Default) {
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

    fun disconnectAll() {
        clients.values.forEach { it.disconnect() }
        clients.clear()
        activeSubscriptions.clear()
        tempClientsLock.withLock {
            temporaryClients.forEach { it.disconnect() }
            temporaryClients.clear()
        }
        lookupPool.closeAll()
        closeMetadataPool()
    }

    // ══════════════════════════════════════════════════════════════════
    // Subscriptions (REQ / CLOSE)
    // ══════════════════════════════════════════════════════════════════

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
                        if (BuildConfig.DEBUG) Log.d(TAG, "NOTICE from $relayUrl: $notice")
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

        // Process metadata and relay list events immediately (before dedup).
        // These overwrite cached state (profiles, relay lists, the owner's blocked
        // list), so only a validly signed, newest-seen event may do that.
        if (kind in REPLACEABLE_STATE_KINDS) {
            if (kind == 10000 && pubkey != ownerHexPubkey) return
            if (!acceptReplaceable(eventObj, kind, pubkey, createdAt)) return
        }
        when (kind) {
            0 -> {
                parseAndCacheProfile(pubkey, content, createdAt)
                return
            }
            10002 -> {
                parseRelayListEvent(pubkey, tags, createdAt)
                return
            }
            10050 -> {
                parseDmRelayListEvent(pubkey, tags)
                return
            }
            10063 -> {
                parseServerListEvent(pubkey, tags, createdAt)
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

    /** Newest accepted created_at per "kind:pubkey" for [REPLACEABLE_STATE_KINDS]. */
    private val replaceableNewest = ConcurrentHashMap<String, Long>()

    /**
     * True when [eventObj] is validly signed and not older than the newest event of
     * the same kind and author already accepted. Records it as the newest.
     */
    private fun acceptReplaceable(eventObj: JsonObject, kind: Int, pubkey: String, createdAt: Long): Boolean {
        val key = "$kind:$pubkey"
        // A profile saved on disk counts as seen, so after a restart an older
        // signed kind-0 cannot replace a newer one.
        val seen = replaceableNewest[key] ?: if (kind == 0) _profiles.value[pubkey]?.createdAt else null
        if (seen != null && createdAt < seen) return false
        if (!HavenBridge.verifyEvent(eventObj.toString())) return false
        replaceableNewest.merge(key, createdAt) { a, b -> maxOf(a, b) }
        return createdAt >= (replaceableNewest[key] ?: createdAt)
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

    private fun clearSeen() = seenLock.withLock {
        seenEventIds.clear()
    }

    // ══════════════════════════════════════════════════════════════════
    // Fetch watchdog
    // ══════════════════════════════════════════════════════════════════

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

        val readRelays = configStore.config.value.readRelays

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

        // The pool shares one sub id, so each REQ *replaces* the last on every
        // relay, and a REQ sent before a socket connects is dropped (send()
        // returns false; only the latest filter is re-sent on connect). A filter
        // of just this flush's pubkeys therefore cancelled every earlier batch
        // still in flight, and those pubkeys were then negatively cached for
        // PROFILE_RETRY_TTL_MS: on a cold start almost every feed author stayed
        // an npub with a letter avatar. Ask for everything still unanswered.
        val filterJson = pendingMetadataFilterJson(now) ?: return
        lastMetadataFilterJson = filterJson

        // Reuse a small pool of WARM connections to the Blastr relays (kind 0 is
        // widely replicated) instead of opening fresh sockets per flush. A stable
        // sub id means each flush just replaces the filter on the open sockets.
        // The user's own relay (first in readRelays when configured) leads,
        // then the profile relays, then the rest of Blastr.
        val relays = (readRelays.take(1) + PROFILE_RELAYS + readRelays)
            .distinct()
            .filter { isValidRelayUrl(it) }
            .take(METADATA_POOL_SIZE)
        if (relays.isEmpty()) return
        metadataPoolLock.withLock {
            // Drop pooled relays no longer in the configured set.
            val keep = relays.toSet()
            metadataClients.keys.filter { it !in keep }.toList().forEach { url ->
                metadataClients.remove(url)?.disconnect()
            }
            for (relayUrl in relays) {
                val client = metadataClients.getOrPut(relayUrl) { createMetadataClient(relayUrl) }
                // CLOSE first: a relay may refuse a REQ that reuses the id of a
                // subscription it still holds open, rather than replace it.
                client.send("[\"CLOSE\",\"$METADATA_SUB_ID\"]")
                client.send("[\"REQ\",\"$METADATA_SUB_ID\",$filterJson]")
            }
        }
        armMetadataIdleTimeout()
    }

    /**
     * kind-0 filter for every pubkey dispatched in the last
     * [METADATA_PENDING_WINDOW_MS] whose metadata has not arrived since, newest
     * first, capped at [METADATA_MAX_AUTHORS]. Null when nothing is pending.
     */
    private fun pendingMetadataFilterJson(now: Long): String? {
        val profiles = _profiles.value
        val staged = profileEmitLock.withLock { pendingProfiles.keys.toSet() }
        val authors = profileQueueLock.withLock {
            profileFetchAttempts.entries
                .filter { (pubkey, attemptedAt) ->
                    now - attemptedAt < METADATA_PENDING_WINDOW_MS &&
                        pubkey !in staged &&
                        (profiles[pubkey]?.fetchedAt ?: 0L) < attemptedAt
                }
                .sortedByDescending { it.value }
                .take(METADATA_MAX_AUTHORS)
                .map { it.key }
        }
        if (authors.isEmpty()) return null
        return buildFilterJson(buildMap<String, Any> {
            put("kinds", listOf(0))
            put("authors", authors)
        })
    }

    /** Open a long-lived metadata-pool connection that survives across flushes. */
    private fun createMetadataClient(relayUrl: String): WebSocketClient {
        val client = WebSocketClient(url = relayUrl, scope = scope)
        scope.launch(Dispatchers.Default) {
            client.messages.collect { msg ->
                launch(Dispatchers.Default) { processRelayMessage(msg, relayUrl) }
            }
        }
        // Re-issue the latest filter on every (re)connect so a dropped subscription
        // recovers without waiting for the next flush.
        scope.launch {
            client.connectionState.collect { state ->
                if (state == WebSocketClient.ConnectionState.CONNECTED) {
                    val filterJson = pendingMetadataFilterJson(System.currentTimeMillis())
                        ?: lastMetadataFilterJson.takeIf { it.isNotEmpty() }
                    if (filterJson != null) {
                        client.send("[\"REQ\",\"$METADATA_SUB_ID\",$filterJson]")
                    }
                }
            }
        }
        client.connect()
        return client
    }

    /** Close the metadata pool after a quiet period to free idle connections. */
    private fun armMetadataIdleTimeout() {
        metadataIdleJob?.cancel()
        metadataIdleJob = scope.launch {
            delay(METADATA_IDLE_TIMEOUT_MS)
            closeMetadataPool()
        }
    }

    private fun closeMetadataPool() {
        metadataIdleJob?.cancel()
        metadataPoolLock.withLock {
            metadataClients.values.forEach { it.disconnect() }
            metadataClients.clear()
        }
    }

    private fun parseAndCacheProfile(pubkey: String, content: String, createdAt: Long) {
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
            // Freshness-only refresh: stage it, but no UI-change signal needed.
            stageProfile(pubkey, existingProfile.copy(fetchedAt = now, createdAt = createdAt), notify = false)
            return
        }

        stageProfile(pubkey, parsed.copy(fetchedAt = now, createdAt = createdAt), notify = true)
    }

    /** Stage a parsed profile for the next batched emission window (see [pendingProfiles]). */
    private fun stageProfile(pubkey: String, profile: FeedProfile, notify: Boolean) {
        profileEmitLock.withLock {
            pendingProfiles[pubkey] = profile
            if (notify) pendingProfileNotify.add(pubkey)
            if (profileEmitJob?.isActive == true) return
            profileEmitJob = scope.launch(Dispatchers.Default) {
                delay(PROFILE_EMIT_DEBOUNCE_MS)
                flushProfileEmissions()
            }
        }
    }

    /** Merge all staged profiles into [_profiles] in ONE rebuild + ONE emission, off-main. */
    private fun flushProfileEmissions() {
        val snapshot: Map<String, FeedProfile>
        val notify: Set<String>
        profileEmitLock.withLock {
            profileEmitJob = null
            if (pendingProfiles.isEmpty()) return
            snapshot = HashMap(pendingProfiles)
            pendingProfiles.clear()
            notify = HashSet(pendingProfileNotify)
            pendingProfileNotify.clear()
        }
        // MutableStateFlow.value writes are thread-safe → do the heavy merge/trim
        // here on Default (this runs from a Dispatchers.Default coroutine).
        _profiles.value = trimProfiles(_profiles.value + snapshot)
        notify.forEach { noteProfileUpdated(it) }
        if (notify.isNotEmpty()) saveProfilesThrottled()
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

    // created_at of the kind-10002 event currently reflected in _relayLists/
    // _outboxRelays, per pubkey — guards against a late-arriving stale relay list
    // (from a lagging relay) clobbering a fresher one, same failure mode as the
    // kind-3 follow-list clobber bug.
    private val relayListCreatedAt = mutableMapOf<String, Long>()

    private fun parseRelayListEvent(pubkey: String, tags: List<List<String>>, createdAt: Long) {
        val (readRelays, writeRelays) = profileRepository.parseRelayListTags(tags)
        scope.launch(Dispatchers.Main.immediate) {
            val known = relayListCreatedAt[pubkey]
            if (known != null && createdAt < known) return@launch
            relayListCreatedAt[pubkey] = createdAt
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

    // Newest 10063 wins: a kiosk vault republishes without its mesh entry
    // when it leaves the mesh, and an older copy must not bring it back.
    private val serverListCreatedAt = mutableMapOf<String, Long>()

    private fun parseServerListEvent(pubkey: String, tags: List<List<String>>, createdAt: Long) {
        val servers = profileRepository.parseServerListTags(tags)
        if (servers.isNotEmpty()) {
            scope.launch(Dispatchers.Main.immediate) {
                val known = serverListCreatedAt[pubkey]
                if (known != null && createdAt < known) return@launch
                serverListCreatedAt[pubkey] = createdAt
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

        val readRelays = configStore.config.value.readRelays
        for (relayUrl in readRelays.take(3)) {
            if (!isValidRelayUrl(relayUrl)) continue
            scope.launch(Dispatchers.IO) {
                lookupPool.query(relayUrl, subId, listOf(buildFilterJson(filter)), TEMP_CLIENT_DISCONNECT_MS) { msg ->
                    launch(Dispatchers.Default) { processRelayMessage(msg, relayUrl) }
                }
            }
        }
    }

    /**
     * Fetch NIP-65 relay lists (kind 10002) for many pubkeys at once, on the
     * pooled lookup sockets. The metadata pool asks for kind 0 only, so a
     * forced [fetchMissingProfiles] never brings these in. Asks the user's own
     * relay and the profile relays (purplepag.es and user.kindpag.es index
     * relay lists).
     */
    fun fetchRelayLists(pubkeys: List<String>) {
        if (pubkeys.isEmpty()) return
        val relays = (configStore.config.value.readRelays.take(1) + PROFILE_RELAYS)
            .distinct()
            .filter { isValidRelayUrl(it) }
        for (chunk in pubkeys.distinct().chunked(RELAY_LIST_CHUNK)) {
            val filter = buildFilterJson(buildMap<String, Any> {
                put("kinds", listOf(10002))
                put("authors", chunk)
                put("limit", chunk.size)
            })
            for (relayUrl in relays) {
                val subId = "relays-${UUID.randomUUID().toString().take(8)}"
                scope.launch(Dispatchers.IO) {
                    lookupPool.query(relayUrl, subId, listOf(filter), RELAY_LIST_TIMEOUT_MS) { msg ->
                        launch(Dispatchers.Default) { processRelayMessage(msg, relayUrl) }
                    }
                }
            }
        }
    }

    /**
     * Fetch [pubkey]'s Blossom server list (kind 10063), which says whether
     * their vault is on the FIPS mesh.
     */
    fun fetchServerList(pubkey: String) {
        // NIP-F1: the list lives on the author's own write relays. Not known
        // yet: ask for their 10002 too, then ask those relays once it lands.
        if (_outboxRelays.value[pubkey] == null) {
            fetchRelayList(pubkey)
            scope.launch {
                delay(TEMP_CLIENT_DISCONNECT_MS)
                if (_outboxRelays.value[pubkey] != null) queryServerList(pubkey, outboxOnly = true)
            }
        }
        queryServerList(pubkey)
    }

    private fun queryServerList(pubkey: String, outboxOnly: Boolean = false) {
        val subId = "servers-${UUID.randomUUID().toString().take(8)}"
        val filter = buildMap<String, Any> {
            put("kinds", listOf(10063))
            put("authors", listOf(pubkey))
            put("limit", 1)
        }

        val outbox = (_outboxRelays.value[pubkey] ?: emptyList()).take(3)
        val relays = if (outboxOnly) outbox
            else (outbox + configStore.config.value.activeBlastrRelays.take(3)).distinct()
        for (relayUrl in relays) {
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
     * Sign in the active signing mode (local key, NIP-46 bunker or Amber) and
     * publish, off the caller's thread. Every event goes through signEventAsync:
     * a separate local-only signer let reactions, reposts, lists and deletes skip
     * the bunker — silently doing nothing for bunker-only accounts.
     */
    fun signAndPost(
        kind: Int,
        content: String,
        tags: List<List<String>> = emptyList(),
        forceOwner: Boolean = false,
    ) {
        scope.launch(Dispatchers.IO) {
            val event = try {
                signEventAsync(kind = kind, content = content, tags = tags, forceOwner = forceOwner)
            } catch (e: Exception) {
                Log.e(TAG, "signAndPost: kind $kind not signed: ${e.message}")
                null
            }
            event?.let { postEvent(it) }
        }
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
        lockedTo: PostingAccount.Lock? = null,
    ): NostrEvent? {
        // With [lockedTo], refuse to sign unless that account is still the
        // active one, and refuse the result unless it carries its key.
        if (lockedTo != null) requireStillPostingAs(lockedTo, eventPubkey = null)
        val event = signEventRouted(kind, content, tags, forceOwner)
        if (lockedTo != null && event != null) requireStillPostingAs(lockedTo, eventPubkey = event.pubkey)
        return event
    }

    /**
     * The account active right now, for `signEventAsync(lockedTo:)`. Take it
     * when Post is tapped, before any upload.
     */
    fun lockPostingAccount(): PostingAccount.Lock {
        val cfg = configStore.config.value
        return PostingAccount.Lock(npub = PostingAccount.resolve(cfg.activeAccountNpub, cfg.ownerNpub), hex = activeHexPubkey)
    }

    /**
     * Throws [PostingAccount.AccountChangedException] unless [lock] is still
     * the active account and, once signed, [eventPubkey] is its key.
     */
    fun requireStillPostingAs(lock: PostingAccount.Lock, eventPubkey: String?) {
        val cfg = configStore.config.value
        val ok = if (eventPubkey == null) {
            PostingAccount.resolve(cfg.activeAccountNpub, cfg.ownerNpub) == lock.npub
        } else {
            PostingAccount.signedAsLocked(lock, cfg.activeAccountNpub, cfg.ownerNpub, eventPubkey)
        }
        if (!ok) {
            Log.w(TAG, "account changed while posting – locked=${lock.npub.take(20)} signed=${eventPubkey?.take(8)}; not publishing")
            throw PostingAccount.AccountChangedException()
        }
    }

    private suspend fun signEventRouted(
        kind: Int,
        content: String,
        tags: List<List<String>>,
        forceOwner: Boolean,
    ): NostrEvent? = withContext(Dispatchers.IO) {
        val signingMode = configStore.config.value.activeSigningMode()
        if (BuildConfig.DEBUG) Log.d(TAG, "signEventAsync: kind=$kind signingMode=$signingMode bridgeLoaded=${com.nostrvault.relay.HavenBridge.isLoaded}")

        // Owner-forced events while another account is active go to the
        // OWNER's own signer (#168 parity), never the active account's.
        val route = SignerRouting.route(configStore.config.value, forceOwner, ownerHexPubkey, activeHexPubkey)
        when (route) {
            is SignerRoute.Unavailable -> throw IllegalStateException(route.reason)
            is SignerRoute.BunkerSession -> {
                val eventJson = EventPublisher.buildUnsignedEvent(
                    kind = kind, content = content,
                    tags = EventPublisher.appendClientTag(tags, kind), pubkey = ownerHexPubkey,
                )
                val signed = gatedIfBackground(kind) { NIP46Service.signEventWith(route.signerPubkey, eventJson) }
                    ?: throw IllegalStateException("The owner's signer is not connected")
                return@withContext requireSignedAsRequested(eventJson, parseSignedEvent(signed), "NIP-46 signer (owner)")
            }
            is SignerRoute.Amber -> if (route.asOwner) {
                val eventJson = EventPublisher.buildUnsignedEvent(
                    kind = kind, content = content,
                    tags = EventPublisher.appendClientTag(tags, kind), pubkey = ownerHexPubkey,
                )
                val signed = amberSignerService.signEvent(eventJson, asOwner = true)
                    ?: throw IllegalStateException("Amber signer failed")
                return@withContext requireSignedAsRequested(eventJson, parseSignedEvent(signed), "Amber (owner)")
            }
            is SignerRoute.Local -> if (route.asOwner && signingMode != "local") {
                return@withContext signLocally(kind, content, tags, forceOwner = true)
            }
            SignerRoute.ActiveBunker -> Unit
        }

        when (signingMode) {
            "nip46" -> {
                val finalTags = EventPublisher.appendClientTag(tags, kind)
                val eventJson = EventPublisher.buildUnsignedEvent(
                    kind = kind,
                    content = content,
                    tags = finalTags,
                    pubkey = if (forceOwner) ownerHexPubkey else activeHexPubkey,
                )
                ensureBunkerConnected()
                val signed = gatedIfBackground(kind) {
                    NIP46Service.signEvent(eventJson, userInitiated = kind in NIP46Service.userActionKinds)
                }
                    ?: throw IllegalStateException("NIP-46 remote signer failed")
                return@withContext requireSignedAsRequested(eventJson, parseSignedEvent(signed), "NIP-46 signer")
            }
            "amber" -> {
                val finalTags = EventPublisher.appendClientTag(tags, kind)
                val eventJson = EventPublisher.buildUnsignedEvent(
                    kind = kind,
                    content = content,
                    tags = finalTags,
                    pubkey = if (forceOwner) ownerHexPubkey else activeHexPubkey,
                )
                val signed = amberSignerService.signEvent(eventJson)
                    ?: throw IllegalStateException("Amber signer failed")
                return@withContext requireSignedAsRequested(eventJson, parseSignedEvent(signed), "Amber")
            }
            else -> {
                // Local signing
                signLocally(kind, content, tags, forceOwner)
            }
        }
    }

    /** Signs with the local key of the owner ([forceOwner]) or the active account. */
    private fun signLocally(kind: Int, content: String, tags: List<List<String>>, forceOwner: Boolean): NostrEvent {
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
        return parseSignedEvent(signed)
            ?: throw IllegalStateException("Failed to parse signed event")
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

    /** Expose owner secret key for NIP-44 self-encryption. */
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
     * With [onBroadcastOutcome], the Blastr broadcast waits for relay `OK`s and
     * reports once: accepted when one relay takes it, refused when none does
     * after the retries (see [broadcastConfirmed]). Called on the main thread.
     */
    fun postEvent(event: NostrEvent, onBroadcastOutcome: ((BroadcastTally.Outcome) -> Unit)? = null) {
        val eventJson = serializeEvent(event)

        // 0. The owner's home vault on the mesh, which passes it on to the
        //    regular relays too. Queued while it is out of reach.
        homeVault.offerEvent(event.id, event.pubkey, eventJson)

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
        val toBlastr: () -> Unit = if (onBroadcastOutcome == null) {
            { broadcastRawEvent(eventJson) }
        } else {
            {
                scope.launch {
                    val outcome = broadcastConfirmed(event, configStore.config.value.activeBlastrRelays)
                    withContext(Dispatchers.Main) { onBroadcastOutcome(outcome) }
                }
            }
        }
        scope.launch(Dispatchers.IO) {
            when (event.kind) {
                0 -> toBlastr() // Profile → Blastr
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
                    toBlastr()
                    // A DM relay list (10050) also goes to the DM relays it
                    // names, where senders look for it (iOS #224).
                    DMInbox.extraBroadcastRelays(event.kind, event.tags, configStore.config.value.activeBlastrRelays)
                        .filter { !isLoopbackRelay(it) }
                        .forEach { fireAndForgetPublish(eventJson, it) }
                }
            }
        }
    }

    /**
     * Sends [event] to [relays] and reports a single outcome. When every relay
     * refuses or times out it tries again, a little later each time, before
     * giving up: a slow relay shouldn't read as a failed post.
     */
    private suspend fun broadcastConfirmed(event: NostrEvent, relays: List<String>): BroadcastTally.Outcome {
        val targets = relays.filter { isValidRelayUrl(it) }
        for (attempt in 0 until 3) {
            if (attempt > 0) delay(if (attempt == 1) 3_000L else 8_000L)
            if (broadcastOnceConfirmed(event, targets) == BroadcastTally.Outcome.ACCEPTED) {
                return BroadcastTally.Outcome.ACCEPTED
            }
        }
        return BroadcastTally.Outcome.REFUSED
    }

    /**
     * One pass over [relays]. Returns as soon as the outcome is decided; the
     * sends to slower relays keep going in [scope] so they still get the post.
     */
    private suspend fun broadcastOnceConfirmed(event: NostrEvent, relays: List<String>): BroadcastTally.Outcome {
        val tally = BroadcastTally(relays.size)
        tally.outcome?.let { return it }
        val decided = CompletableDeferred<BroadcastTally.Outcome>()
        for (relayUrl in relays) {
            scope.launch(Dispatchers.IO) {
                val (ok, message) = try {
                    publishAwaitingOk(event, relayUrl, timeoutMs = 10_000)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    false to "connection failed"
                }
                tally.record(relayUrl, ok, message)?.let { decided.complete(it) }
            }
        }
        return decided.await()
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

    /**
     * Also send [event] to [relayUrl], e.g. diVine's relay for a diVine, and
     * wait for its OK. Returns whether it accepted and its message; a relay
     * that never answers within [timeoutMs] counts as not accepted.
     */
    suspend fun publishAwaitingOk(event: NostrEvent, relayUrl: String, timeoutMs: Long = 15_000): Pair<Boolean, String> {
        if (!isValidRelayUrl(relayUrl)) return false to "bad relay address"
        val eventJson = serializeEvent(event)
        return withContext(Dispatchers.IO) {
            val client = WebSocketClient(url = relayUrl, scope = scope)
            try {
                withTimeoutOrNull(timeoutMs) {
                    coroutineScope {
                        // Listen before connecting; the flow does not replay.
                        val answer = async(start = CoroutineStart.UNDISPATCHED) {
                            client.messages.mapNotNull { okReply(it, event.id) }.first()
                        }
                        client.connect()
                        client.send("[\"EVENT\",$eventJson]")
                        answer.await()
                    }
                } ?: (false to "it didn't answer")
            } finally {
                client.disconnect()
            }
        }
    }

    /** `["OK", <eventId>, <accepted>, <message>]` for [eventId], else null. */
    private fun okReply(message: String, eventId: String): Pair<Boolean, String>? = runCatching {
        val parsed = Json.parseToJsonElement(message).jsonArray
        if (parsed.size < 3 || parsed[0].jsonPrimitive.contentOrNull != "OK") return@runCatching null
        if (parsed[1].jsonPrimitive.contentOrNull != eventId) return@runCatching null
        val accepted = parsed[2].jsonPrimitive.booleanOrNull ?: false
        accepted to (parsed.getOrNull(3)?.jsonPrimitive?.contentOrNull ?: "")
    }.getOrNull()

    /**
     * Sends [pubkey]'s newest profile (kind 0), exactly as already signed, to
     * [relayUrl] in the background. diVine's search and author pages only know
     * profiles that reach its own relay, which otherwise happens only for
     * people who have used the diVine app. Nothing is signed, so no signer prompt.
     */
    fun sendProfileTo(pubkey: String, relayUrl: String) {
        scope.launch {
            val profile = fetchNewestReplaceable(kind = 0, pubkey = pubkey, alsoAsk = emptyList()) ?: return@launch
            publishFireAndForget(profile, listOf(relayUrl))
        }
    }

    /**
     * Also send [event] to [relays] without waiting for their answers, e.g. the
     * relays a poll names for its votes (iOS broadcastRawEvent extraRelays).
     */
    fun publishFireAndForget(event: NostrEvent, relays: List<String>) {
        val eventJson = serializeEvent(event)
        relays.filter { isValidRelayUrl(it) && !isLoopbackRelay(it) }
            .forEach { fireAndForgetPublish(eventJson, it) }
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

    /**
     * Which key signs a list "for [accountNpub]": the owner's (forceOwner) or the
     * active account's. null means neither can — another, inactive account —
     * and publishing must be skipped rather than overwrite a different
     * identity's replaceable list with this one's.
     */
    private fun forceOwnerFor(accountNpub: String): Boolean? {
        val cfg = configStore.config.value
        return when (accountNpub) {
            "", cfg.ownerNpub -> true
            cfg.activeOrOwnerNpub() -> false
            else -> null
        }
    }

    fun publishMuteList(accountNpub: String, blockedNpubs: List<String>) {
        val forceOwner = forceOwnerFor(accountNpub) ?: run {
            Log.w(TAG, "publishMuteList: ${accountNpub.take(12)} is not the owner or active account; not published")
            return
        }
        val tags = blockedNpubs.mapNotNull { npub ->
            npubToHex(npub)?.let { listOf("p", it) }
        }
        signAndPost(kind = 10000, content = "", tags = tags, forceOwner = forceOwner)
    }

    fun publishRelayList(accountNpub: String) {
        val forceOwner = forceOwnerFor(accountNpub) ?: run {
            Log.w(TAG, "publishRelayList: ${accountNpub.take(12)} is not the owner or active account; not published")
            return
        }
        val tags = configStore.config.value.publicRelayListTags
        if (tags.isEmpty()) return
        signAndPost(kind = 10002, content = "", tags = tags, forceOwner = forceOwner)
    }

    /**
     * Republishes kind 10050 for the owner account.
     *
     * Builds shipped a 10050 leading with 127.0.0.1, making those accounts
     * undeliverable — senders wrote the gift wrap to their own machine. 10050 is
     * replaceable, so publishing a clean one overwrites the broken one on every
     * relay holding it, and from then on *any* sender reaches them, including
     * ones still running the old build.
     */
    fun republishDMRelayList() {
        scope.launch(Dispatchers.IO) {
            runCatching { syncOwnerDMInboxList() }
                .onFailure { Log.w(TAG, "DM inbox sync failed: ${it.message}") }
        }
    }

    /**
     * Brings the owner's DM inbox list (kind 10050) into step across devices:
     * the newest published list is adopted unless this device published a
     * newer one, in which case ours is published. Every device used to
     * republish its own settings at launch, so whichever device opened last
     * silently replaced the list the others had set. See [DMInbox].
     */
    private suspend fun syncOwnerDMInboxList() {
        val owner = ownerHexPubkey
        if (owner.isBlank()) return
        val config = configStore.config.value
        val newest = fetchNewestDMRelayList(owner, config.dmInboxRelays)
        val published = newest?.first?.filter { !isLoopbackRelay(it) }

        var action = DMInbox.syncAction(config.dmInboxRelays, config.dmRelaysUpdatedAt, published, newest?.second)
        if (action == DMInbox.SyncAction.ADOPT && newest != null && published != null) {
            configStore.updateAsync {
                it.copy(dmRelays = published.ifEmpty { it.dmRelays }, dmRelaysUpdatedAt = newest.second)
            }
            if (BuildConfig.DEBUG) Log.i(TAG, "Adopted published DM inbox list (${published.size} relays)")
            // This device may still hold more than was published (its own
            // Haven inbox, or loopback entries dropped).
            action = DMInbox.syncAction(configStore.config.value.dmInboxRelays, newest.second, newest.first, newest.second)
        }
        if (action == DMInbox.SyncAction.PUBLISH) publishOwnerDMInboxList()
    }

    /**
     * Publishes this device's DM inbox list for the owner and stamps it as the
     * newest change. Call when the Haven relay address changes.
     */
    fun publishOwnerDMInboxList() {
        configStore.update { it.copy(dmRelaysUpdatedAt = System.currentTimeMillis() / 1000) }
        publishDMRelayList(configStore.config.value.dmInboxRelays)
    }

    /**
     * The newest signed kind 10050 for [pubkey] across the blastr relays and
     * [alsoAsk], as (relays, created_at), or null if none answered in time.
     * Asks fresh rather than trusting the cached [dmRelayLists], which would
     * let a device adopt its own stale copy.
     */
    private suspend fun fetchNewestDMRelayList(pubkey: String, alsoAsk: List<String>, timeoutMs: Long = 6_000): Pair<List<String>, Long>? {
        val winner = fetchNewestReplaceable(10050, pubkey, alsoAsk, timeoutMs) ?: return null
        return profileRepository.parseDMRelayListTags(winner.tags) to winner.createdAt
    }

    /**
     * The newest signed replaceable event of [kind] by [pubkey] across the
     * blastr relays and [alsoAsk], or null if none answered in time. Asks
     * fresh: the profile caches can hold a list replaced long ago.
     */
    suspend fun fetchNewestReplaceable(kind: Int, pubkey: String, alsoAsk: List<String>, timeoutMs: Long = 6_000): NostrEvent? =
        lookupNewestReplaceable(kind, pubkey, alsoAsk, timeoutMs).event

    /**
     * One [lookupNewestReplaceable] answer: the newest event, and how many
     * relays were asked and answered (EOSE). No event with every relay
     * answered means there genuinely is none, not that the lookup timed out.
     */
    data class ReplaceableLookup(val event: NostrEvent?, val asked: Int, val answered: Int) {
        val confirmedNone: Boolean get() = event == null && asked > 0 && answered >= asked
    }

    /** [fetchNewestReplaceable], also saying whether "none" was confirmed. */
    suspend fun lookupNewestReplaceable(kind: Int, pubkey: String, alsoAsk: List<String>, timeoutMs: Long = 6_000): ReplaceableLookup {
        val targets = (configStore.config.value.activeBlastrRelays + alsoAsk)
            .map { it.trim() }
            .filter { it.isNotEmpty() && !isLoopbackRelay(it) }
            .distinct()
        if (targets.isEmpty()) return ReplaceableLookup(null, 0, 0)
        val best = java.util.concurrent.atomic.AtomicReference<NostrEvent?>(null)
        val answered = java.util.concurrent.atomic.AtomicInteger(0)
        coroutineScope {
            targets.map { url ->
                launch(Dispatchers.IO) {
                    val client = WebSocketClient(url = url, scope = this, autoReconnect = false)
                    try {
                        withTimeoutOrNull(timeoutMs) {
                            val subId = "dmlist-${UUID.randomUUID().toString().take(6)}"
                            val done = CompletableDeferred<Unit>()
                            val collector = launch {
                                client.messages.collect { msg ->
                                    val arr = runCatching { json.parseToJsonElement(msg).jsonArray }.getOrNull() ?: return@collect
                                    when (arr.getOrNull(0)?.jsonPrimitive?.contentOrNull) {
                                        "EVENT" -> {
                                            val obj = arr.getOrNull(2)?.jsonObject ?: return@collect
                                            val ev = parseSignedEvent(obj.toString()) ?: return@collect
                                            if (ev.kind != kind || ev.pubkey != pubkey || !HavenBridge.verifyEvent(obj.toString())) return@collect
                                            best.updateAndGet { cur -> if (cur == null || ev.createdAt > cur.createdAt) ev else cur }
                                        }
                                        "EOSE" -> {
                                            val ours = arr.getOrNull(1)?.jsonPrimitive?.contentOrNull == subId
                                            if (done.complete(Unit) && ours) answered.incrementAndGet()
                                        }
                                        "CLOSED" -> done.complete(Unit)
                                    }
                                }
                            }
                            launch {
                                client.connectionState.first { it == WebSocketClient.ConnectionState.CONNECTED }
                                client.send("""["REQ","$subId",{"kinds":[$kind],"authors":["$pubkey"],"limit":1}]""")
                            }
                            client.connect()
                            done.await()
                            collector.cancel()
                        }
                    } finally {
                        client.disconnect()
                    }
                }
            }.joinAll()
        }
        return ReplaceableLookup(best.get(), targets.size, answered.get())
    }

    fun publishDMRelayList(dmRelays: List<String>) {
        // A kind 10050 is a PUBLIC announcement of where others should deliver
        // DMs to us. The embedded Haven relay lives on 127.0.0.1 and is never
        // reachable by anyone else, so loopback URLs must be stripped — otherwise
        // senders are told to deliver replies to an address they can't reach.
        var relays = dmRelays.filter { !isLoopbackRelay(it) }
        // Never publish an empty list — fall back to public defaults.
        if (relays.isEmpty()) {
            relays = listOf(
                "wss://relay.primal.net",
                "wss://nos.lol",
                "wss://relay.btcforplebs.com",
            )
        }
        // NIP-17 tags are ["relay", url]. Builds before this wrote ["r", url],
        // which no other client reads — they saw an empty list and had nowhere
        // to deliver our DMs.
        val tags = relays.map { listOf("relay", it) }
        signAndPost(kind = 10050, content = "", tags = tags, forceOwner = true)
    }

    /**
     * NIP-51: publishes the owner's blocked relay list (kind 10006), the relays
     * set to Never connect. An empty list is published too, so unblocking the
     * last relay clears it.
     */
    fun publishBlockedRelayList() {
        val tags = configStore.config.value.blockedRelays.map { listOf("relay", DMInbox.normalizedRelayURL(it)) }
        signAndPost(kind = 10006, content = "", tags = tags, forceOwner = true)
    }

    fun publishServerList() {
        val mirrors = configStore.config.value.activeBlossomMirrors
        if (mirrors.isEmpty()) return
        scope.launch(Dispatchers.IO) {
            // Merge into the newest signed list, so a kiosk's fipsmesh:// entry
            // survives this phone editing its own servers. The cache only when
            // the relays couldn't say; a confirmed "none" starts empty.
            val owner = ownerHexPubkey
            val lookup = runCatching {
                lookupNewestReplaceable(10063, owner, _outboxRelays.value[owner].orEmpty().take(3))
            }.getOrNull()
            val newest = when {
                lookup?.event != null -> profileRepository.parseServerListTags(lookup.event.tags)
                lookup?.confirmedNone == true -> emptyList()
                else -> _serverLists.value[owner].orEmpty()
            }
            val servers = com.nostrvault.fips.HomeVaultRules.mergeServerList(newest, mirrors)
            signAndPost(kind = 10063, content = "", tags = servers.map { listOf("server", it) }, forceOwner = true)
        }
    }

    fun deleteNote(noteId: String) {
        val tags = listOf(listOf("e", noteId))
        signAndPost(kind = 5, content = "", tags = tags)
    }

    fun reportEvent(eventId: String, pubkey: String, reason: String, description: String? = null) {
        val tags = mutableListOf(
            listOf("e", eventId),
            listOf("p", pubkey),
            listOf("reason", reason),
        )
        signAndPost(kind = 1984, content = description ?: "", tags = tags)
    }

    fun reportUser(pubkey: String, reason: String, description: String? = null) {
        val tags = mutableListOf(
            listOf("p", pubkey),
            listOf("reason", reason),
        )
        signAndPost(kind = 1984, content = description ?: "", tags = tags)
    }

    // ══════════════════════════════════════════════════════════════════
    // Search
    // ══════════════════════════════════════════════════════════════════

    /**
     * Starts a search session and returns it; the caller collects
     * [GlobalSearchSession.state] and cancels the session when the query
     * changes. Returns null for a query too short to search.
     *
     * Relay scope ([includeGlobal] false) walks the phone's embedded relay only.
     * Global adds the Mac relay (if configured) and the configured NIP-50
     * search relays, all at once.
     */
    fun startSearch(query: String, includeGlobal: Boolean, follows: Set<String>, wot: Set<String> = emptySet()): GlobalSearchSession? {
        val matcher = SearchTermMatcher.create(query) ?: return null
        val config = configStore.config.value
        val plan = GlobalSearchSession.Plan(
            phoneRelayUrl = config.nostrURL,
            macRelayUrl = if (includeGlobal) config.macRelayWssURL.ifEmpty { null } else null,
            searchRelays = if (includeGlobal) config.activeSearchRelays else emptyList(),
        )
        val session = GlobalSearchSession(
            query = query.trim(),
            matcher = matcher,
            plan = plan,
            own = ownSearchPubkeys(),
            follows = follows,
            wot = wot,
            cachedProfiles = _profiles.value.values.toList(),
            onFinished = { results -> scope.launch { mergeSearchProfiles(results.profiles) } },
        )
        session.start()
        return session
    }

    /** Active account and the owner (iOS parity: `request.own`). */
    private fun ownSearchPubkeys(): Set<String> {
        val owner = configStore.config.value.ownerNpub
            .takeIf { it.startsWith("npub1") }
            ?.let { HavenBridge.decodeNpub(it) }
        return setOfNotNull(
            configStore.activeAccountHexPubkey.value.takeIf { it.isNotEmpty() },
            owner?.takeIf { it.isNotEmpty() },
        )
    }

    /** Profiles a search discovered join the cache, so result rows and mentions resolve. */
    fun mergeSearchProfiles(found: List<FeedProfile>) {
        if (found.isEmpty()) return
        val now = System.currentTimeMillis()
        val current = _profiles.value
        val additions = found.filter { !current.containsKey(it.pubkey) }
            .associate { it.pubkey to it.copy(fetchedAt = now) }
        if (additions.isNotEmpty()) _profiles.value = current + additions
    }

    /** Who a callback search belongs to; each gets its own slot. */
    enum class SearchCaller { FEED, MENTION }

    /**
     * One in-flight callback search per caller. Feed search and @-mention
     * lookup used to share one slot, so a mention lookup cancelled the feed's
     * search, whose callback then never fired and left its spinner on.
     */
    private val callbackSearches = java.util.concurrent.ConcurrentHashMap<SearchCaller, GlobalSearchSession>()

    /**
     * One-shot NIP-50 search over the configured search relays, delivered once
     * every relay has answered (or the per-relay cap passed). Used by the feed's
     * search and @-mention lookup; the Search screen streams via [startSearch].
     *
     * A search replaced by a newer one from the same [caller], or cancelled via
     * [cancelGlobalSearch], never calls [onResult]: delivery is checked on the
     * main thread against the caller's current session, so a session cancelled
     * after it finished cannot hand back stale results either.
     */
    fun globalSearch(
        query: String,
        caller: SearchCaller = SearchCaller.FEED,
        onResult: (GlobalSearchResults) -> Unit,
    ) {
        cancelGlobalSearch(caller)
        val matcher = SearchTermMatcher.create(query)
        if (matcher == null) {
            onResult(GlobalSearchResults())
            return
        }
        val session = GlobalSearchSession(
            query = query.trim(),
            matcher = matcher,
            plan = GlobalSearchSession.Plan(
                phoneRelayUrl = null,
                macRelayUrl = null,
                searchRelays = configStore.config.value.activeSearchRelays,
            ),
            own = ownSearchPubkeys(),
            follows = emptySet(),
            onFinished = { results -> deliverCallbackSearch(caller, results, onResult) },
        )
        callbackSearches[caller] = session
        session.start()
    }

    private fun deliverCallbackSearch(
        caller: SearchCaller,
        results: GlobalSearchResults,
        onResult: (GlobalSearchResults) -> Unit,
    ) {
        scope.launch {
            mergeSearchProfiles(results.profiles)
            // Still this caller's search? `results` belongs to the session that
            // produced it; compare by the finished session's identity.
            val current = callbackSearches[caller] ?: return@launch
            if (current.finishedResults !== results) return@launch
            callbackSearches.remove(caller, current)
            onResult(results)
        }
    }

    fun cancelGlobalSearch(caller: SearchCaller = SearchCaller.FEED) {
        callbackSearches.remove(caller)?.cancel()
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
                    // The pool subscribes to a socket's messages before it
                    // connects, so an early EVENT/EOSE is not dropped.
                    val filter = """{"kinds":[1],"authors":["$pubkey"],"limit":50}"""
                    lookupPool.query(relayUrl, subId, listOf(filter), TEMP_CLIENT_DISCONNECT_MS) { msg ->
                        try {
                            val parsed = json.parseToJsonElement(msg).jsonArray
                            // EOSE frames are ["EOSE", subId] (size 2). A < 3
                            // guard dropped them before the EOSE handler, so the
                            // collected notes were never delivered via onResult.
                            if (parsed.size < 2) return@query
                            val type = parsed[0].jsonPrimitive.contentOrNull ?: return@query
                            val sid = parsed[1].jsonPrimitive.contentOrNull ?: return@query
                            if (type == "EVENT" && sid == subId) {
                                val ev = parsed[2].jsonObject
                                val id = ev["id"]?.jsonPrimitive?.contentOrNull ?: return@query
                                val pk = ev["pubkey"]?.jsonPrimitive?.contentOrNull ?: return@query
                                val content = ev["content"]?.jsonPrimitive?.contentOrNull ?: ""
                                val createdAt = ev["created_at"]?.jsonPrimitive?.longOrNull ?: 0L
                                val kind = ev["kind"]?.jsonPrimitive?.intOrNull ?: return@query
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
    fun profileStream(pubkey: String): ProfileStream = ProfileStream(pubkey, profileRelayUrls(pubkey))

    /** The relays a profile page asks: local, up to 3 feed relays, up to 3 of the profile's outbox. */
    fun profileRelayUrls(pubkey: String): List<String> {
        val config = configStore.config.value
        return buildList {
            config.nostrURL?.let { add(it) }
            addAll(config.readRelays.take(3))
            // NIP-65 outbox model: we're fetching events FROM this user, so query
            // their write/outbox relays (where they actually publish), not their
            // read/inbox relays (where others send things TO them).
            _outboxRelays.value[pubkey]?.let { addAll(it.take(3)) }
        }.distinct().take(6)
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

        /** Note authored by [pubkey] (kinds 1/6/30023, and 1068 polls). */
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
            val notes = """{"kinds":[1,6,30023,${NIP88Poll.KIND}],"authors":["$pubkey"],"limit":50}"""
            val meta = """{"kinds":[0],"authors":["$pubkey"],"limit":1}"""
            val contacts = """{"kinds":[3],"authors":["$pubkey"],"limit":1}"""
            val followers = """{"kinds":[3],"#p":["$pubkey"],"limit":100}"""
            val tagged = """{"kinds":[1,6,30023,${NIP88Poll.KIND}],"#p":["$pubkey"],"limit":50}"""
            return "[\"REQ\",\"$initialSubId\",$notes,$meta,$contacts,$followers,$tagged]"
        }

        fun loadOlder(until: Long) {
            val subId = "older-${UUID.randomUUID().toString().take(6)}"
            val filter = """{"kinds":[1,6,30023,${NIP88Poll.KIND}],"authors":["$pubkey"],"until":$until,"limit":50}"""
            clients.forEach { it.send("[\"REQ\",\"$subId\",$filter]") }
        }

        fun loadOlderTagged(until: Long) {
            val subId = "older-tagged-${UUID.randomUUID().toString().take(6)}"
            val filter = """{"kinds":[1,6,30023,${NIP88Poll.KIND}],"#p":["$pubkey"],"until":$until,"limit":50}"""
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
                    kind == 0 && evPubkey == pubkey -> {
                        if (acceptReplaceable(ev, kind, evPubkey, createdAt)) parseAndCacheProfile(pubkey, content, createdAt)
                    }
                    kind == 3 && evPubkey == pubkey -> {
                        val pTags = tags.filter { it.size >= 2 && it[0] == "p" }
                        val following = pTags.map { it[1] }.filter { it != pubkey }.distinct().size
                        val followsMe = ourHexKeys.isNotEmpty() && pTags.any { ourHexKeys.contains(it[1]) }
                        onContacts?.invoke(following, followsMe)
                    }
                    kind == 3 && evPubkey != pubkey -> onFollower?.invoke(evPubkey)
                    kind == 1 || kind == 6 || kind == 30023 || kind == NIP88Poll.KIND -> {
                        // fromEvent() resolves NIP-18 reposts (kind 6 → original
                        // author as pubkey, repostedBy = the reposter), which powers
                        // the profile Reposts tab + repost attribution.
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
     * Fetch a whole thread for the note-detail view. Queries the entire subtree
     * by NIP-10 thread [rootId] (so siblings and the wider thread appear when a
     * mid-thread reply is opened, not just direct replies to the opened note),
     * the [focusedId]'s own direct replies, and fetches the root plus any
     * [ancestorIds] by id so missing parents are filled in from the network.
     * Mirrors iOS NoteDetailView (fetchReplies by root + fetchParents by ids).
     */
    private val COMMENT = NIP10Thread.COMMENT_KIND

    fun fetchThread(
        rootId: String,
        focusedId: String,
        ancestorIds: List<String>,
        rootCoordinate: String? = null,
        onRawEvent: ((String, String) -> Unit)? = null,
        onResult: (List<FeedNote>) -> Unit,
    ) {
        fun jsonArr(values: List<String>) =
            values.distinct().joinToString(",") { "\"$it\"" }
        // #e by root + focused note + all ancestors so legacy replies that only
        // tag their direct parent (not the thread root) are still fetched.
        val eIds = (listOf(rootId, focusedId) + ancestorIds).distinct()
        // NIP-22 comments (1111) tag their direct parent in lowercase e too.
        val eFilter = """{"kinds":[1,$COMMENT],"#e":[${jsonArr(eIds)}],"limit":200}"""
        // NIP-22 comments name the thread root in uppercase E, so one filter
        // reaches them at any depth (iOS NoteDetailView commentsFilter).
        val commentsFilter = """{"kinds":[$COMMENT],"#E":[${jsonArr(listOf(rootId))}],"limit":150}"""
        // Root note itself + ancestors are not replies, so fetch by id. An
        // ancestor of a comment is usually itself a comment.
        val idValues = (listOf(rootId) + ancestorIds).distinct()
        val idFilter = """{"kinds":[1,$COMMENT],"ids":[${jsonArr(idValues)}]}"""
        // Comments on an addressable or replaceable root name it by A; an
        // edited article has a new event id, so #E alone misses them.
        val filters = mutableListOf(eFilter, commentsFilter, idFilter)
        if (rootCoordinate != null) {
            filters.add("""{"kinds":[$COMMENT],"#A":[${jsonArr(listOf(rootCoordinate))}],"limit":150}""")
        }
        queryDetailRelays(filters, onRawEvent, onEose = onResult)
    }

    /**
     * Responses to [rootId] that aren't thread rows (spec "below the fold"):
     * quotes of any kind (#q) plus highlights (9802) and voice replies (1244).
     * The caller decides which of these are quotes rather than replies.
     *
     * [rootCoordinate] is the root's address when it is addressable: an
     * article's highlights name it by its `a` coordinate, not by this
     * version's id, so `#e` alone never finds them (iOS #189).
     */
    fun fetchOtherResponses(rootId: String, rootCoordinate: String? = null, onResult: (List<FeedNote>) -> Unit) {
        val filters = mutableListOf(
            """{"#q":["$rootId"],"limit":50}""",
            """{"kinds":[9802,1244],"#e":["$rootId"],"limit":50}""",
        )
        if (rootCoordinate != null) {
            filters.add("""{"kinds":[9802,1244],"#a":[${JsonPrimitive(rootCoordinate)}],"limit":50}""")
        }
        queryDetailRelays(
            filters,
            onRawEvent = null,
            onEose = onResult,
            acceptKinds = null,
        )
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
        queryDetailRelays(listOf("""{"kinds":[1,$COMMENT,${NIP88Poll.KIND}],"ids":["$id"]}"""), onRawEvent) { notes ->
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
            listOf("""{"kinds":[1,$COMMENT],"#e":[$idArr],"limit":150}"""),
            onRawEvent,
            onEose = onResult,
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
        /** Kinds to keep; null keeps every kind. */
        acceptKinds: Set<Int>? = setOf(1, NIP10Thread.COMMENT_KIND),
        onEose: (List<FeedNote>) -> Unit,
    ) {
        val config = configStore.config.value
        val relayUrls = buildList {
            config.nostrURL?.let { add(it) }
            config.inboxRelays?.let { addAll(it) }
            // Replies from other users propagate to feed/blastr relays, not just
            // the local + inbox relays. Mirror iOS (NoteDetailView) which queries
            // external feed relays so strangers' replies are actually found.
            addAll(config.readRelays)
            addAll(config.writeRelays)
        }.distinct().take(8)
        if (relayUrls.isEmpty()) { onEose(emptyList()); return }

        val subId = "replies-${UUID.randomUUID().toString().take(8)}"
        val collected = java.util.concurrent.ConcurrentHashMap<String, FeedNote>()

        for (relayUrl in relayUrls) {
            scope.launch(Dispatchers.IO) {
                try {
                    lookupPool.query(relayUrl, subId, filters, TEMP_CLIENT_DISCONNECT_MS) { msg ->
                        try {
                            val parsed = json.parseToJsonElement(msg).jsonArray
                            // EOSE is ["EOSE", subId] (size 2); a < 3 guard dropped
                            // it so onEose never fired and replies/thread results
                            // were never delivered. Same bug as fetchProfileNotes.
                            if (parsed.size < 2) return@query
                            val type = parsed[0].jsonPrimitive.contentOrNull ?: return@query
                            val sid = parsed[1].jsonPrimitive.contentOrNull ?: return@query
                            if (type == "EVENT" && sid == subId) {
                                val ev = parsed[2].jsonObject
                                val id = ev["id"]?.jsonPrimitive?.contentOrNull ?: return@query
                                val pk = ev["pubkey"]?.jsonPrimitive?.contentOrNull ?: return@query
                                val content = ev["content"]?.jsonPrimitive?.contentOrNull ?: ""
                                val createdAt = ev["created_at"]?.jsonPrimitive?.longOrNull ?: 0L
                                val kind = ev["kind"]?.jsonPrimitive?.intOrNull ?: return@query
                                val tags: List<List<String>> = try {
                                    ev["tags"]?.jsonArray?.map { t -> t.jsonArray.map { it.jsonPrimitive.content } } ?: emptyList()
                                } catch (_: Exception) { emptyList() }

                                if (acceptKinds == null || kind in acceptKinds) {
                                    collected[id] = FeedNote.fromEvent(id, pk, content, tags, createdAt, kind)
                                    onRawEvent?.invoke(id, ev.toString())
                                }
                            }
                            if (type == "EOSE" && sid == subId) {
                                onEose(collected.values.sortedBy { it.createdAt })
                            }
                        } catch (_: Exception) {}
                    }
                } catch (_: Exception) {}
            }
        }
    }

    /**
     * One-shot REQ that hands back the raw events: sends [filters] (JSON
     * objects) to every relay in [relayUrls] on temporary clients and
     * collects events, deduplicated by id, until each relay has sent EOSE or
     * CLOSED (or dropped the connection) or [timeoutMs] passes. Any kind; the
     * caller decides what the events are. [onProgress], when given, gets the
     * events so far each time a relay finishes, on an IO thread. [onAnswered]
     * runs when a relay sends EOSE, so a caller can tell "relays had nothing"
     * from "no relay answered".
     */
    suspend fun queryRawEvents(
        filters: List<String>,
        relayUrls: List<String>,
        timeoutMs: Long = 5_000L,
        onAnswered: (() -> Unit)? = null,
        onProgress: ((List<JsonObject>) -> Unit)? = null,
    ): List<JsonObject> {
        if (filters.isEmpty() || relayUrls.isEmpty()) return emptyList()
        val subId = "q-${UUID.randomUUID().toString().take(8)}"
        val collected = ConcurrentHashMap<String, JsonObject>()

        // Each relay's lookup ends at its EOSE/CLOSED, or at once when the
        // relay refuses the socket (or refused one in the last two minutes).
        withTimeoutOrNull(timeoutMs) {
            coroutineScope {
                for (relayUrl in relayUrls) launch(Dispatchers.IO) {
                    val outcome = lookupPool.query(relayUrl, subId, filters, timeoutMs) { msg ->
                        handleRawQueryMessage(msg, subId, collected)
                    }
                    if (outcome == LookupSocketPool.Outcome.EOSE) onAnswered?.invoke()
                    // What has arrived so far, as each relay finishes, so a
                    // caller need not wait for the slowest one.
                    if (onProgress != null && collected.isNotEmpty()) onProgress(collected.values.toList())
                }
            }
        }
        return collected.values.toList()
    }

    /**
     * NIP-45 COUNT for [filter] on one relay, on the pooled lookup socket.
     * Null when the relay refuses COUNT (most do), doesn't answer in
     * [timeoutMs], or sends no number.
     */
    suspend fun countEvents(relayUrl: String, filter: Map<String, Any>, timeoutMs: Long = 8_000L): Int? {
        if (!isValidRelayUrl(relayUrl)) return null
        val subId = "count-${UUID.randomUUID().toString().take(8)}"
        var count: Int? = null
        lookupPool.query(relayUrl, subId, listOf(buildFilterJson(filter)), timeoutMs, verb = "COUNT") { msg ->
            count = countFrom(msg) ?: count
        }
        return count
    }

    private val vertexCache = com.nostrvault.data.model.VertexReputation.Cache()

    /**
     * [target]'s follower count from Vertex, the source npub.world uses. Null
     * when Vertex can't answer: no local key (a bunker or Amber would be asked
     * to sign for every profile opened), no credits, or no answer in time.
     * The request is signed by the active account and names [target].
     * Mirrors iOS NostrService.fetchVertexFollowerCount.
     */
    suspend fun fetchVertexFollowerCount(target: String, timeoutMs: Long = 6_000): Int? {
        val vertex = com.nostrvault.data.model.VertexReputation
        val now = System.currentTimeMillis()
        vertexCache.followers(target, now)?.let { return it }
        if (!vertexCache.shouldAsk(now) || configStore.config.value.activeSigningMode() != "local") return null
        val request = withContext(Dispatchers.IO) {
            runCatching { signLocally(vertex.REQUEST_KIND, "", vertex.requestTags(target), forceOwner = false) }.getOrNull()
        } ?: return null

        val reply = withContext(Dispatchers.IO) {
            coroutineScope {
                val client = WebSocketClient(url = vertex.RELAY_URL, scope = this, autoReconnect = false)
                try {
                    withTimeoutOrNull(timeoutMs) {
                        val subId = "vertex-${UUID.randomUUID().toString().take(6)}"
                        val answer = CompletableDeferred<com.nostrvault.data.model.VertexReputation.Reply>()
                        val collector = launch {
                            client.messages.collect { msg ->
                                val arr = runCatching { json.parseToJsonElement(msg).jsonArray }.getOrNull() ?: return@collect
                                if (arr.getOrNull(0)?.jsonPrimitive?.contentOrNull != "EVENT") return@collect
                                val obj = arr.getOrNull(2)?.jsonObject ?: return@collect
                                val ev = parseSignedEvent(obj.toString()) ?: return@collect
                                val r = vertex.reply(ev.kind, ev.pubkey, ev.tags, ev.content, request.id, target) ?: return@collect
                                if (HavenBridge.verifyEvent(obj.toString())) answer.complete(r)
                            }
                        }
                        launch {
                            client.connectionState.first { it == WebSocketClient.ConnectionState.CONNECTED }
                            // Listen first, so a fast answer isn't missed.
                            client.send("""["REQ","$subId",{"kinds":[${vertex.RESULT_KIND},${vertex.FEEDBACK_KIND}],"#e":["${request.id}"]}]""")
                            client.send("[\"EVENT\",${serializeEvent(request)}]")
                        }
                        client.connect()
                        answer.await().also { collector.cancel() }
                    }
                } finally {
                    client.disconnect()
                    coroutineContext.cancelChildren()
                }
            }
        } ?: return null // No answer in time says nothing about credits.

        vertexCache.record(reply, target, System.currentTimeMillis())
        return (reply as? com.nostrvault.data.model.VertexReputation.Reply.Followers)?.count
    }

    /** Stores an EVENT for [subId]; true once the relay is done (EOSE/CLOSED). */
    private fun handleRawQueryMessage(
        msg: String,
        subId: String,
        collected: MutableMap<String, JsonObject>,
    ): Boolean {
        val parsed = try { json.parseToJsonElement(msg).jsonArray } catch (_: Exception) { return false }
        if (parsed.size < 2) return false
        val type = (parsed[0] as? JsonPrimitive)?.contentOrNull ?: return false
        if ((parsed[1] as? JsonPrimitive)?.contentOrNull != subId) return false
        return when (type) {
            "EVENT" -> {
                val ev = parsed.getOrNull(2) as? JsonObject
                val id = (ev?.get("id") as? JsonPrimitive)?.contentOrNull
                if (ev != null && id != null) collected[id] = ev
                false
            }
            "EOSE", "CLOSED" -> true
            else -> false
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
                lookupPool.query(relayUrl, subId, listOf(buildFilterJson(filter)), TEMP_CLIENT_DISCONNECT_MS) { msg ->
                    launch(Dispatchers.Default) { processRelayMessage(msg, relayUrl) }
                }
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Fetch zap receipts
    // ══════════════════════════════════════════════════════════════════

    /** [tagFilter] narrows the request, e.g. `"#P" to listOf(me)` for zaps you sent. */
    fun fetchZapReceipts(relayUrls: List<String>, limit: Int = 1000, tagFilter: Map<String, List<String>> = emptyMap()) {
        val subId = "zaps-${UUID.randomUUID().toString().take(8)}"
        val filter = buildFilterJson(buildMap<String, Any> {
            put("kinds", listOf(9735))
            put("limit", limit)
            putAll(tagFilter)
        })

        for (relayUrl in relayUrls) {
            scope.launch(Dispatchers.IO) {
                val client = WebSocketClient(url = relayUrl, scope = scope)
                tempClientsLock.withLock { temporaryClients.add(client) }

                scope.launch(Dispatchers.Default) {
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

    private fun serializeEvent(event: NostrEvent): String = EventPublisher.serializeSignedEvent(event)

    /**
     * The Go bunker session only exists in this process: after a restart nothing
     * reconnected it until the user switched accounts, so every signature failed.
     * Reconnect with the active account's stored bunker config, and refuse a
     * signer that answers for a different account.
     */
    private suspend fun ensureBunkerConnected() {
        val cfg = configStore.config.value
        val bunker = cfg.bunkerConfig(cfg.activeOrOwnerNpub())
            ?: throw IllegalStateException("No bunker configured for this account")
        // The connect/ensure decision runs under NIP46Service's lock and checks
        // the signer's key; a wrong-key signer is dropped, not kept.
        NIP46Service.connectForAccount(bunker, activeHexPubkey)
            ?: throw IllegalStateException(NIP46Service.lastError.value ?: "Could not reach the bunker")
    }

    /**
     * Background signer work (relay AUTH, the 10050 / 10063 lists) goes to a
     * remote signer one request at a time; what the person does (posts,
     * reactions, zaps) is never queued behind it. Upload auth (24242 Blossom,
     * 27235 HTTP) is not queued either: it is almost always a photo the person
     * just attached, and queued it waited silently behind an unanswered relay
     * AUTH for the signer's full timeout.
     */
    private val backgroundSignerGate = kotlinx.coroutines.sync.Semaphore(1)
    private val backgroundSignerKinds = setOf(22242, 10002, 10050, 10063, 10000)

    private suspend fun <T> gatedIfBackground(kind: Int, block: suspend () -> T): T =
        if (kind in backgroundSignerKinds) backgroundSignerGate.withPermit { block() } else block()

    /**
     * An external signer's answer is only accepted if it is the event we asked
     * for, under the pubkey we asked for. A valid signature proves nothing about
     * identity: a signer paired to another account signs happily as that account.
     */
    private fun requireSignedAsRequested(requestJson: String, signed: NostrEvent?, signer: String): NostrEvent {
        if (signed == null) throw IllegalStateException("$signer returned an unreadable event")
        val req = this.json.parseToJsonElement(requestJson).jsonObject
        val wantPubkey = req["pubkey"]?.jsonPrimitive?.contentOrNull
        val wantTags = req["tags"]?.jsonArray?.map { t -> t.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" } }
        if (signed.pubkey != wantPubkey) {
            throw IllegalStateException("$signer signed as ${signed.pubkey.take(8)}…, not this account (${wantPubkey?.take(8)}…)")
        }
        if (signed.kind != req["kind"]?.jsonPrimitive?.intOrNull ||
            signed.createdAt != req["created_at"]?.jsonPrimitive?.longOrNull ||
            signed.content != req["content"]?.jsonPrimitive?.contentOrNull ||
            signed.tags != wantTags
        ) {
            throw IllegalStateException("$signer changed the event it was asked to sign")
        }
        return signed
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
