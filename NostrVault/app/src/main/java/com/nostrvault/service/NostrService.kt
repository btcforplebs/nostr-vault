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
    internal val configStore: ConfigStore,
    internal val credentialStore: CredentialStore,
    internal val profileRepository: ProfileRepository,
    private val eventPublisher: EventPublisher,
    internal val amberSignerService: AmberSignerService,
    internal val powPreferences: com.nostrvault.data.local.PowPreferences,
    internal val lookupPool: LookupSocketPool,
) {
    companion object {
        /** Kinds whose newest event replaces cached state; see [acceptReplaceable]. */
        internal val REPLACEABLE_STATE_KINDS = setOf(0, 10000, 10002, 10050, 10063)

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

        internal const val TAG = "NostrService"
        internal const val MAX_SEEN_IDS = 50_000
        internal const val TRIM_SEEN_IDS = 40_000
        internal const val MAX_EVENTS = 10_000
        internal const val BUFFER_FLUSH_DELAY_MS = 300L
        internal const val PROFILE_SAVE_THROTTLE_MS = 5_000L
        internal const val PROFILE_FLUSH_DELAY_MS = 100L
        internal const val PROFILE_EMIT_DEBOUNCE_MS = 200L
        internal const val PROFILE_UPDATE_DEBOUNCE_MS = 100L
        // A cached profile is "fresh" for this long before we'll re-fetch its metadata.
        internal const val PROFILE_TTL_MS = 7L * 24 * 60 * 60 * 1000 // 7 days
        // After dispatching a metadata REQ, suppress re-fetching the same pubkey for this
        // long. This negatively-caches pubkeys with no resolvable kind-0 (and dedupes
        // in-flight fetches) so they don't re-trigger a 3-relay fetch on every note.
        internal const val PROFILE_RETRY_TTL_MS = 30L * 60 * 1000 // 30 min
        // Soft cap on in-memory profiles; trimmed to TRIM_CACHED_PROFILES when exceeded.
        internal const val MAX_CACHED_PROFILES = 5_000
        internal const val TRIM_CACHED_PROFILES = 4_000
        // Prune the fetch-attempt map once it grows past this.
        internal const val MAX_FETCH_ATTEMPTS = 10_000
        private const val FETCH_WATCHDOG_TIMEOUT_MS = 8_000L
        private const val MAX_RECONNECT_ATTEMPTS = 10
        private const val BASE_RECONNECT_DELAY_MS = 2_000L
        private const val MAX_RECONNECT_DELAY_MS = 30_000L
        internal const val TEMP_CLIENT_DISCONNECT_MS = 3_000L

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
        internal const val METADATA_POOL_SIZE = 10
        // Asked for names/avatars ahead of the Blastr relays. On 2026-10-01,
        // for 300 recent posters, the default Blastr set (nos.lol and
        // nostr.mom unreachable, primal ~11%) had 115 profiles; adding these
        // reached 193. Re-measure with `.scratch/profprobe/probe.py` in the
        // Buzz nest before changing it. offchain.pub refused connections on
        // 2026-10-12 and was dropped.
        val PROFILE_RELAYS = listOf(
            "wss://relay.damus.io",
            "wss://user.kindpag.es",
            "wss://purplepag.es",
        )
        internal const val METADATA_IDLE_TIMEOUT_MS = 60_000L
        internal const val METADATA_SUB_ID = "meta-pool"
        // How long a dispatched pubkey stays in the pool's filter waiting for
        // its kind 0, and the most authors one REQ carries.
        internal const val METADATA_PENDING_WINDOW_MS = 60_000L
        internal const val METADATA_MAX_AUTHORS = 500
        // Authors per kind-10002 REQ in fetchRelayLists, and how long each waits.
        internal const val RELAY_LIST_CHUNK = 200
        internal const val RELAY_LIST_TIMEOUT_MS = 8_000L
    }

    internal val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    internal val json = Json { ignoreUnknownKeys = true }

    // ── Observable state ──────────────────────────────────────────────

    internal val _connectionStatus = MutableStateFlow("Disconnected")
    val connectionStatus: StateFlow<String> = _connectionStatus.asStateFlow()

    internal val _connectionColor = MutableStateFlow("gray")
    val connectionColor: StateFlow<String> = _connectionColor.asStateFlow()

    internal val _isFetching = MutableStateFlow(false)
    val isFetching: StateFlow<Boolean> = _isFetching.asStateFlow()

    internal val _profiles = MutableStateFlow<Map<String, FeedProfile>>(emptyMap())
    val profiles: StateFlow<Map<String, FeedProfile>> = _profiles.asStateFlow()

    internal val _relayLists = MutableStateFlow<Map<String, List<String>>>(emptyMap())
    val relayLists: StateFlow<Map<String, List<String>>> = _relayLists.asStateFlow()

    internal val _outboxRelays = MutableStateFlow<Map<String, List<String>>>(emptyMap())
    val outboxRelays: StateFlow<Map<String, List<String>>> = _outboxRelays.asStateFlow()

    internal val _dmRelayLists = MutableStateFlow<Map<String, List<String>>>(emptyMap())
    val dmRelayLists: StateFlow<Map<String, List<String>>> = _dmRelayLists.asStateFlow()

    internal val _serverLists = MutableStateFlow<Map<String, List<String>>>(emptyMap())
    val serverLists: StateFlow<Map<String, List<String>>> = _serverLists.asStateFlow()

    internal val _profileUpdates = MutableSharedFlow<ProfileUpdateSignal>(replay = 0)
    val profileUpdates: SharedFlow<ProfileUpdateSignal> = _profileUpdates.asSharedFlow()

    /** Emitted whenever the main event list is mutated. */
    internal val _eventUpdates = MutableSharedFlow<Unit>(replay = 0, extraBufferCapacity = 1)
    val eventUpdates: SharedFlow<Unit> = _eventUpdates.asSharedFlow()

    // ── Internal mutable state ────────────────────────────────────────

    var events: List<NostrEvent> = emptyList()
        internal set
    var noteMedia: List<MediaItem> = emptyList()
        internal set
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

    internal val clients = ConcurrentHashMap<String, WebSocketClient>()
    internal val activeSubscriptions = ConcurrentHashMap<String, String>()
    internal val temporaryClients = mutableSetOf<WebSocketClient>()
    internal val tempClientsLock = ReentrantLock()

    /** Limits concurrent temporary WebSocket connections to prevent OOM. */
    internal val tempClientSemaphore = Semaphore(8)

    // ── Warm metadata (kind-0) connection pool ────────────────────────
    // A few reused, long-lived connections to Blastr relays for profile fetches.
    // Replaces opening 3 fresh sockets per flush (the handshake churn rate-limited
    // us — 429 — so profiles/names/pics stopped loading). Guarded by metadataPoolLock.
    internal val metadataClients = HashMap<String, WebSocketClient>()
    internal val metadataPoolLock = ReentrantLock()
    internal var metadataIdleJob: Job? = null
    @Volatile internal var lastMetadataFilterJson: String = ""

    // ── Reconnection backoff ──────────────────────────────────────────

    internal val reconnectAttempts = ConcurrentHashMap<String, Int>()
    internal val lastReconnectTime = ConcurrentHashMap<String, Long>()
    internal val relaysReconnecting = ConcurrentHashMap.newKeySet<String>()

    // ── Deduplication ─────────────────────────────────────────────────

    internal val seenEventIds = LinkedHashSet<String>()
    internal val seenLock = ReentrantLock()

    // ── Event batching ────────────────────────────────────────────────

    internal val eventBuffer = mutableListOf<Pair<NostrEvent, List<MediaItem>>>()
    internal val bufferLock = ReentrantLock()
    internal var bufferFlushJob: Job? = null

    // ── Profile fetching ──────────────────────────────────────────────

    internal val profileFetchQueue = mutableSetOf<String>()
    internal val profileQueueLock = ReentrantLock()
    // pubkey -> epoch millis of last dispatched metadata REQ (negative/in-flight cache).
    // Guarded by profileQueueLock.
    internal val profileFetchAttempts = mutableMapOf<String, Long>()
    internal var profileFlushJob: Job? = null
    internal var profileSaveJob: Job? = null
    // Epoch millis the latest scheduled save runs at (see saveProfilesThrottled).
    internal var lastProfileSaveTime = 0L
    // Reading profiles.json; saves wait for it so they never write a partial cache.
    internal var profileDiskLoad: Job? = null

    // ── Profile-map emission batching ─────────────────────────────────
    // Incoming kind-0 profiles are staged here and merged into _profiles in ONE
    // map rebuild + ONE emission per debounce window, off the main thread. Doing
    // it per-profile copied the entire (≤5,000-entry) map and recomposed every
    // collector on each arrival — a main-thread allocation/recomposition storm
    // while profiles stream in during feed load. All guarded by profileEmitLock.
    internal val pendingProfiles = HashMap<String, FeedProfile>()
    internal val pendingProfileNotify = HashSet<String>()
    internal var profileEmitJob: Job? = null
    internal val profileEmitLock = ReentrantLock()

    // ── Profile update coalescing ─────────────────────────────────────

    internal val pendingProfileUpdates = mutableSetOf<String>()
    internal val profileUpdateLock = ReentrantLock()
    internal var profileUpdateJob: Job? = null
    internal var profileUpdateGeneration = 0

    // ── Fetch tracking ────────────────────────────────────────────────

    internal var activeSubscriptionCount = 0
    internal var fetchWatchdogJob: Job? = null

    // ── Account switch ────────────────────────────────────────────────

    internal var accountSwitchJob: Job? = null

    // ══════════════════════════════════════════════════════════════════
    // Initialization
    // ══════════════════════════════════════════════════════════════════

    init {
        initialize()
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

    /** Newest accepted created_at per "kind:pubkey" for [REPLACEABLE_STATE_KINDS]. */
    internal val replaceableNewest = ConcurrentHashMap<String, Long>()

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

    // created_at of the kind-10002 event currently reflected in _relayLists/
    // _outboxRelays, per pubkey — guards against a late-arriving stale relay list
    // (from a lagging relay) clobbering a fresher one, same failure mode as the
    // kind-3 follow-list clobber bug.
    internal val relayListCreatedAt = mutableMapOf<String, Long>()

    /**
     * Sign a Nostr event asynchronously (supports NIP-46 remote signing).
     * Throws IllegalStateException with diagnostic info on failure.
     * With [silentOnly], Amber signs only if it can without its approval
     * screen (see [AmberSignerService.signEvent]); otherwise this throws.
     */
    suspend fun signEventAsync(
        kind: Int,
        content: String,
        tags: List<List<String>> = emptyList(),
        password: String? = null,
        forceOwner: Boolean = false,
        lockedTo: PostingAccount.Lock? = null,
        silentOnly: Boolean = false,
    ): NostrEvent? {
        // With [lockedTo], refuse to sign unless that account is still the
        // active one, and refuse the result unless it carries its key.
        if (lockedTo != null) requireStillPostingAs(lockedTo, eventPubkey = null)
        val event = signEventRouted(kind, content, tags, forceOwner, silentOnly)
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

    /** Expose owner secret key for NIP-44 self-encryption. */
    fun resolveOwnerSecretKey(): String? = resolveSecretKey(forceOwner = true)

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
     * Publishes this device's DM inbox list for the owner and stamps it as the
     * newest change. Call when the Haven relay address changes.
     */
    fun publishOwnerDMInboxList() {
        configStore.update { it.copy(dmRelaysUpdatedAt = System.currentTimeMillis() / 1000) }
        publishDMRelayList(configStore.config.value.dmInboxRelays)
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
        val tags = mirrors.map { listOf("server", it) }
        signAndPost(kind = 10063, content = "", tags = tags, forceOwner = true)
    }

    /** Your own loaded posts that link the blob [referencingBlob]; see [BlobPostDeletion.referencing]. */
    fun ownEvents(referencingBlob: String): List<NostrEvent> =
        BlobPostDeletion.referencing(events, activeHexPubkey, referencingBlob)

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

    /**
     * Shows [profile] for [pubkey] at once, ahead of the relays: your own
     * edit while it publishes, or what was shown before when that failed.
     * Null removes the entry.
     */
    fun showLocalProfile(pubkey: String, profile: FeedProfile?) {
        _profiles.update { if (profile == null) it - pubkey else it + (pubkey to profile) }
        noteProfileUpdated(pubkey)
        saveProfilesThrottled()
    }

    /**
     * Who a callback search belongs to; each gets its own slot. WOT is the
     * WOT tab's "Find someone", so typing there never cancels a feed search.
     */
    enum class SearchCaller { FEED, MENTION, WOT }

    /**
     * One in-flight callback search per caller. Feed search and @-mention
     * lookup used to share one slot, so a mention lookup cancelled the feed's
     * search, whose callback then never fired and left its spinner on.
     */
    internal val callbackSearches = java.util.concurrent.ConcurrentHashMap<SearchCaller, GlobalSearchSession>()

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

    fun cancelGlobalSearch(caller: SearchCaller = SearchCaller.FEED) {
        callbackSearches.remove(caller)?.cancel()
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

        /** Relay keys this stream has asked, so [addRelays] opens only new ones. */
        private val asked = java.util.Collections.synchronizedSet(mutableSetOf<String>())
        @Volatile private var closed = false
        fun start() = addRelays(relayUrls)

        /**
         * Opens the same REQ on [urls] not asked yet, adding to the open
         * stream (no reload); [loadOlder] pages them too. For the outbox,
         * once their kind 10002 arrives.
         */
        fun addRelays(urls: List<String>) {
            for (relayUrl in urls) {
                if (closed || !asked.add(LookupSocketPool.relayKey(relayUrl))) continue
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

        /** Pages [pubkey]'s notes older than [until]; see [OlderRequest]. */
        fun loadOlder(until: Long) = askOlder("older-", """"authors":["$pubkey"]""", until)
        /** Pages notes that p-tag [pubkey], older than [until]; see [OlderRequest]. */
        fun loadOlderTagged(until: Long) = askOlder("older-tagged-", """"#p":["$pubkey"]""", until)

        private fun askOlder(prefix: String, who: String, until: Long): OlderRequest {
            val subId = prefix + UUID.randomUUID().toString().take(6)
            val filter = """{"kinds":[1,6,30023,${NIP88Poll.KIND}],$who,"until":$until,"limit":50}"""
            return OlderRequest(subId, clients.count { it.send("[\"REQ\",\"$subId\",$filter]") })
        }

        fun close() {
            closed = true
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

    private val COMMENT = NIP10Thread.COMMENT_KIND

    /** The whole thread around [focusedId]. See NostrServiceFetching.kt threadQuery. */
    fun fetchThread(
        rootId: String,
        focusedId: String,
        ancestorIds: List<String>,
        rootCoordinate: String? = null,
        onRawEvent: ((String, String) -> Unit)? = null,
        onResult: (List<FeedNote>) -> Unit,
    ) = threadQuery(rootId, focusedId, ancestorIds, rootCoordinate, onRawEvent, onResult)

    /** Quotes, highlights and voice replies. See NostrServiceFetching.kt otherResponsesQuery. */
    fun fetchOtherResponses(rootId: String, rootCoordinate: String? = null, onResult: (List<FeedNote>) -> Unit) =
        otherResponsesQuery(rootId, rootCoordinate, onResult)

    /**
     * Fetch a single note of any kind by id from the detail relay set. Used as a
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
        // No kinds: pictures, videos, highlights and articles open by id too.
        // Only the asked-for id is kept, so nothing else can slip in.
        queryDetailRelays(listOf("""{"ids":["$id"]}"""), onRawEvent, acceptKinds = null) { notes ->
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

    /**
     * Background signer work (relay AUTH, the 10050 / 10063 lists) goes to a
     * remote signer one request at a time; what the person does (posts,
     * reactions, zaps) is never queued behind it. Upload auth (24242 Blossom,
     * 27235 HTTP) is not queued either: it is almost always a photo the person
     * just attached, and queued it waited silently behind an unanswered relay
     * AUTH for the signer's full timeout.
     */
    internal val backgroundSignerGate = kotlinx.coroutines.sync.Semaphore(1)
    internal val backgroundSignerKinds = setOf(22242, 10002, 10050, 10063, 10000)

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
