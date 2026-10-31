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
    internal val configStore: ConfigStore,
    internal val credentialStore: CredentialStore,
    internal val profileRepository: ProfileRepository,
    private val eventPublisher: EventPublisher,
    internal val amberSignerService: AmberSignerService,
    internal val powPreferences: com.nostrvault.data.local.PowPreferences,
    internal val lookupPool: LookupSocketPool,
    internal val homeVault: com.nostrvault.fips.HomeVaultSender,
) {
    companion object {
        /** Kinds whose newest event replaces cached state; see [acceptReplaceable]. */
        internal val REPLACEABLE_STATE_KINDS = setOf(0, 10000, 10002, 10050, 10063)
        /** Lists cached on disk; their created_at is cached alongside (kind 0 keeps its own). */
        internal val PERSISTED_LIST_KINDS = setOf(10002, 10050, 10063)

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
        // Every flush re-sends the whole pending filter to each pooled relay, damus
        // among them, so a short window turned a feed's scroll into a REQ every
        // 100 ms. Two seconds gathers a screenful into one.
        internal const val PROFILE_FLUSH_DELAY_MS = 2_000L
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

    /** Newest accepted event per "kind:pubkey" for [REPLACEABLE_STATE_KINDS],
     *  seeded lazily from disk. Declared above init. */
    internal val replaceableNewest = ReplaceableLedger { profileRepository.loadListStampsIfReady() }

    init {
        initialize()
        FipsMediaRouter.serverLists = { _serverLists.value }
        FipsMediaRouter.requestServerList = { fetchServerList(it) }
        FipsMediaRouter.ownerHex = { ownerHexPubkey }
        BlossomUriLoader.serverLists = { _serverLists.value }
        BlossomUriLoader.requestServerList = { fetchServerList(it) }
        BlossomUriLoader.ownServers = { configStore.config.value.blossomMirrors }
        homeVault.ownerHex = { ownerHexPubkey }
        homeVault.ownerIsActive = { ownerHexPubkey.isNotEmpty() && activeHexPubkey == ownerHexPubkey }
        homeVault.signerIsLocal = {
            SignerRouting.route(configStore.config.value, true, ownerHexPubkey, activeHexPubkey) is SignerRoute.Local
        }
        homeVault.signer = { kind, content, tags ->
            signEventAsync(kind = kind, content = content, tags = tags, forceOwner = true)?.let { serializeEvent(it) }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Event processing pipeline
    // ══════════════════════════════════════════════════════════════════

    fun processRelayMessage(message: String, relayUrl: String) { processRelayMessageImpl(message, relayUrl) }

    // ══════════════════════════════════════════════════════════════════
    // Profile management
    // ══════════════════════════════════════════════════════════════════

    fun fetchMissingProfiles(pubkeys: List<String>, force: Boolean = false) { fetchMissingProfilesImpl(pubkeys, force) }

    // created_at of the kind-10002 event currently reflected in _relayLists/
    // _outboxRelays, per pubkey — guards against a late-arriving stale relay list
    // (from a lagging relay) clobbering a fresher one, same failure mode as the
    // kind-3 follow-list clobber bug.
    internal val relayListCreatedAt = mutableMapOf<String, Long>()

    // Newest 10063 wins: a kiosk vault republishes without its mesh entry
    // when it leaves the mesh, and an older copy must not bring it back.
    internal val serverListCreatedAt = mutableMapOf<String, Long>()

    /**
     * Fetch [pubkey]'s Blossom server list (kind 10063), which says whether
     * their vault is on the FIPS mesh.
     */
    fun fetchServerList(pubkey: String) { fetchServerListImpl(pubkey) }

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
    ): NostrEvent? = signEventAsyncImpl(kind, content, tags, password, forceOwner, lockedTo, silentOnly)

    fun lockPostingAccount(): PostingAccount.Lock = lockPostingAccountImpl()

    fun requireStillPostingAs(lock: PostingAccount.Lock, eventPubkey: String?) { requireStillPostingAsImpl(lock, eventPubkey) }

    /** Expose owner secret key for NIP-44 self-encryption. */
    fun resolveOwnerSecretKey(): String? = resolveSecretKey(forceOwner = true)

    // ══════════════════════════════════════════════════════════════════
    // Event publishing
    // ══════════════════════════════════════════════════════════════════

    fun postEvent(event: NostrEvent, onBroadcastOutcome: ((BroadcastTally.Outcome) -> Unit)? = null) { postEventImpl(event, onBroadcastOutcome) }

    suspend fun publishAwaitingOk(event: NostrEvent, relayUrl: String, timeoutMs: Long = 15_000): Pair<Boolean, String> = publishAwaitingOkImpl(event, relayUrl, timeoutMs)

    fun sendProfileTo(pubkey: String, relayUrl: String) { sendProfileToImpl(pubkey, relayUrl) }

    fun publishFireAndForget(event: NostrEvent, relays: List<String>) { publishFireAndForgetImpl(event, relays) }

    /** Blocks or unblocks on the published mute list; returns what to tell the person when it wasn't published. */
    suspend fun publishMuteListChange(
        accountNpub: String,
        add: List<String> = emptyList(),
        remove: List<String> = emptyList(),
        localBlocks: List<String>,
        privateBefore: Collection<String> = emptyList(),
    ): String? = publishMuteListChangeImpl(accountNpub, add, remove, localBlocks, privateBefore)


    fun adoptPublishedDMRelayList() { adoptPublishedDMRelayListImpl() }

    /** On a saved Haven relay address change: swaps the inbox on the published 10050 only. */
    fun publishOwnerDMInboxMove(oldInbox: String, newInbox: String) { publishOwnerDMInboxMoveImpl(oldInbox, newInbox) }

    suspend fun lookupOwnerRelayLists(): com.nostrvault.relay.RelayDraft.Published = lookupOwnerRelayListsImpl()

    fun publishOwnerRelayListTags(tags: List<List<String>>, before: List<List<String>>, openedAt: Long?, onDone: (Boolean) -> Unit = {}) {
        publishOwnerRelayListTagsImpl(tags, before, openedAt, onDone)
    }

    suspend fun fetchNewestReplaceable(kind: Int, pubkey: String, alsoAsk: List<String>, timeoutMs: Long = 6_000): NostrEvent? = fetchNewestReplaceableImpl(kind, pubkey, alsoAsk, timeoutMs)

    /**
     * One [lookupNewestReplaceable] answer: the newest event, and how many
     * relays were asked and answered (EOSE). No event with every relay
     * answered means there genuinely is none, not that the lookup timed out.
     */
    data class ReplaceableLookup(
        val event: NostrEvent?,
        val asked: Int,
        val answered: Int,
        /** The relays that answered. */
        val answeredBy: Set<String> = emptySet(),
        /** The relays that sent [event]. */
        val from: Set<String> = emptySet(),
    ) {
        val confirmedNone: Boolean get() = event == null && asked > 0 && answered >= asked
    }

    /** With [dTag], an addressable event (kinds 30000-39999) at that `d` tag. */
    suspend fun lookupNewestReplaceable(kind: Int, pubkey: String, alsoAsk: List<String>, timeoutMs: Long = 6_000, dTag: String? = null): ReplaceableLookup = lookupNewestReplaceableImpl(kind, pubkey, alsoAsk, timeoutMs, dTag)

    fun publishBlockedRelayList() { publishBlockedRelayListImpl() }

    /** [dropMesh]: the home vault this phone listed before, when it changed. */
    fun publishServerList(dropMesh: Collection<String> = emptyList()) { publishServerListImpl(dropMesh) }

    /** Adopts media servers from the owner's published kind 10063. See [syncOwnerServerList]. */
    fun syncServerList() {
        scope.launch(Dispatchers.IO) {
            runCatching { syncOwnerServerList() }
                .onFailure { Log.w(TAG, "Media server list sync failed: ${it.message}") }
        }
    }

    /** Your own loaded posts that link the blob [referencingBlob]; see [BlobPostDeletion.referencing]. */
    fun ownEvents(referencingBlob: String): List<NostrEvent> =
        BlobPostDeletion.referencing(events, activeHexPubkey, referencingBlob)

    fun reportEvent(eventId: String, pubkey: String, reason: String, description: String? = null) { reportEventImpl(eventId, pubkey, reason, description) }

    fun reportUser(pubkey: String, reason: String, description: String? = null) { reportUserImpl(pubkey, reason, description) }

    // ══════════════════════════════════════════════════════════════════
    // Search
    // ══════════════════════════════════════════════════════════════════

    fun startSearch(query: String, includeGlobal: Boolean, follows: Set<String>, wot: Set<String> = emptySet()): GlobalSearchSession? = startSearchImpl(query, includeGlobal, follows, wot)

    fun showLocalProfile(pubkey: String, profile: FeedProfile?) { showLocalProfileImpl(pubkey, profile) }

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
    ) { globalSearchImpl(query, caller, onResult) }

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
        /** EOSE (subId, relay URL). subId prefix is "profile-" (initial), "older-", or "older-tagged-". */
        var onEose: ((String, String) -> Unit)? = null

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
                        .collect { msg -> handleMessage(msg, relayUrl) }
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

        private fun handleMessage(msg: String, relayUrl: String) {
            try {
                val parsed = json.parseToJsonElement(msg).jsonArray
                if (parsed.size < 2) return
                val type = parsed[0].jsonPrimitive.contentOrNull ?: return
                val sid = parsed[1].jsonPrimitive.contentOrNull ?: return
                if (type == "EOSE") { onEose?.invoke(sid, relayUrl); return }
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

    internal val COMMENT = NIP10Thread.COMMENT_KIND

    /** The whole thread around [focusedId]. See NostrServiceFetching.kt threadQuery. */
    fun fetchThread(
        rootId: String,
        focusedId: String,
        ancestorIds: List<String>,
        rootCoordinate: String? = null,
        onRawEvent: ((String, String) -> Unit)? = null,
        onResult: (List<FeedNote>) -> Unit,
    ) = fetchThreadImpl(rootId, focusedId, ancestorIds, rootCoordinate, onRawEvent, onResult)

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
    ) { fetchNoteByIdImpl(id, onRawEvent, onResult) }

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
    ) { fetchRepliesForImpl(noteIds, onRawEvent, onResult) }

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
    ): List<JsonObject> = queryRawEventsImpl(filters, relayUrls, timeoutMs, onAnswered, onProgress)

    suspend fun countEvents(relayUrl: String, filter: Map<String, Any>, timeoutMs: Long = 8_000L): Int? = countEventsImpl(relayUrl, filter, timeoutMs)

    internal val vertexCache = com.nostrvault.data.model.VertexReputation.Cache()

    suspend fun fetchVertexFollowerCount(target: String, timeoutMs: Long = 6_000): Int? = fetchVertexFollowerCountImpl(target, timeoutMs)

    // ══════════════════════════════════════════════════════════════════
    // Fetch notes by ID
    // ══════════════════════════════════════════════════════════════════

    fun fetchNotesByIds(ids: List<String>, relayUrls: List<String>) { fetchNotesByIdsImpl(ids, relayUrls) }

    // ══════════════════════════════════════════════════════════════════
    // Fetch zap receipts
    // ══════════════════════════════════════════════════════════════════

    fun fetchZapReceipts(relayUrls: List<String>, limit: Int = 1000, tagFilter: Map<String, List<String>> = emptyMap()) { fetchZapReceiptsImpl(relayUrls, limit, tagFilter) }

    // ══════════════════════════════════════════════════════════════════
    // Lifecycle
    // ══════════════════════════════════════════════════════════════════

    fun injectEvent(event: NostrEvent) { injectEventImpl(event) }

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
