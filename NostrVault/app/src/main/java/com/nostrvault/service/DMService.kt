package com.nostrvault.service

import android.util.Log
import com.nostrvault.BuildConfig
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.CredentialStore
import com.nostrvault.data.model.BlockedPeople
import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.HavenConfig
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.locks.ReentrantLock
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.concurrent.withLock

/**
 * DM service supporting NIP-17 (gift-wrap) and NIP-04 (legacy) protocols.
 * Manages conversations, message sending/receiving, and relay synchronization.
 *
 * Port of DMService.swift.
 */
@Singleton
class DMService @Inject constructor(
    internal val configStore: ConfigStore,
    internal val credentialStore: CredentialStore,
    internal val nostrService: NostrService,
    internal val amberSignerService: AmberSignerService,
) {
    companion object {
        internal const val TAG = "DMService"
        internal const val EXTERNAL_FETCH_MAX_RELAYS = 15
        internal const val LIVE_EXTERNAL_MAX_RELAYS = 8
        internal const val PERIODIC_SYNC_INTERVAL_MS = 5 * 60 * 1000L // 5 minutes
        internal const val FIRE_AND_FORGET_FLUSH_MS = 300L
        private const val FIRE_AND_FORGET_TIMEOUT_MS = 3_000L
        private const val AUTH_TIMEOUT_MS = 5_000L
        internal const val EXTERNAL_FETCH_OVERLAP_MS = 60 * 60 * 1000L // 1 hour overlap
        // NIP-59 backdates a gift wrap's created_at by up to 2 days; plus a minute.
        internal const val GIFT_WRAP_BACKDATE_SECONDS = 2 * 24 * 60 * 60L + 60
        internal const val OPTIMISTIC_DEDUP_THRESHOLD_MS = 30_000L
        private const val MAX_INJECTED_DM_IDS = 5_000
        internal const val CACHE_SAVE_DEBOUNCE_MS = 500L
        private const val MAX_OPENED_MESSAGES = 200
        internal const val MAX_SENT_SELF_WRAP_IDS = 500
    }

    internal val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    internal val json = Json { ignoreUnknownKeys = true }

    // ── Observable state ──────────────────────────────────────────────

    internal val _conversations = MutableStateFlow<List<DMConversation>>(emptyList())

    /**
     * The inbox as shown: conversations with a blocked person are hidden. They
     * stay in [_conversations] (and the cache), so unblocking brings them back.
     */
    val conversations: StateFlow<List<DMConversation>> =
        combine(_conversations, configStore.config.map { blockedHex(it) }.distinctUntilChanged()) { convos, blocked ->
            BlockedPeople.visibleConversations(convos, blocked) { it.id }
        }.stateIn(scope, SharingStarted.Eagerly, emptyList())

    internal val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    /** Count of inbound DMs queued for (Amber) decryption but not yet processed.
     *  Drives an optional "N pending" indicator; drained by [decryptPending]. */
    internal val _pendingDecryptCount = MutableStateFlow(0)
    val pendingDecryptCount: StateFlow<Int> = _pendingDecryptCount.asStateFlow()

    val totalUnreadCount: Int
        get() = conversations.value.sumOf { it.unreadCount }

    val totalUnreadCountFlow: StateFlow<Int> = conversations
        .map { convos -> convos.sumOf { it.unreadCount } }
        .stateIn(scope, SharingStarted.WhileSubscribed(5_000), 0)

    // ── Internal state ────────────────────────────────────────────────

    internal var inboxClient: WebSocketClient? = null     // NIP-17 /chat relay
    internal var nip04Client: WebSocketClient? = null     // NIP-04 /inbox relay
    internal var chatInjectionClient: WebSocketClient? = null
    internal var inboxInjectionClient: WebSocketClient? = null
    /** Persistent live subscriptions to the user's PUBLIC DM relays. */
    internal val liveExternalClients = mutableListOf<WebSocketClient>()
    internal var periodicSyncJob: Job? = null
    internal var chatResubJob: Job? = null

    internal val seenGiftWrapIds = ConcurrentHashMap.newKeySet<String>()

    // ── Notification lookups ──────────────────────────────────────────
    // The relay raises a notification marker for every DM event it stores,
    // and the marker cannot say who wrote a gift wrap. These let
    // LocalNotificationService tell your own sent copies apart and show the
    // real sender and text.

    /** Ids of the self-copy wraps this device sent. */
    internal val sentSelfWrapIds = ConcurrentHashMap.newKeySet<String>()

    /** Recently decrypted DMs by event id → (counterparty, message). */
    internal val openedMessages = java.util.Collections.synchronizedMap(
        object : LinkedHashMap<String, Pair<String, DMMessage>>() {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Pair<String, DMMessage>>?) =
                size > MAX_OPENED_MESSAGES
        },
    )

    /** The conversation whose thread is on screen, so its notifications can stay quiet. */
    @Volatile var visibleConversation: String? = null

    internal val injectedDmIds = ConcurrentHashMap.newKeySet<String>()

    // ── Lazy (Amber) decryption queue ─────────────────────────────────
    // In Amber mode we must NOT decrypt inbound DMs in the background: every
    // decrypt is a remote-signer round-trip funneled through one app-wide lock,
    // so a backlog would hammer Amber and stall all other signing. Instead we
    // queue raw wraps and drain them sequentially, on demand, only while a DM
    // screen is open. (Pattern borrowed from dark-wisp's pendingGiftWraps.)
    internal val pendingDecryptQueue = java.util.concurrent.ConcurrentLinkedQueue<JsonObject>()
    internal val queuedDecryptIds = ConcurrentHashMap.newKeySet<String>()
    private val decryptDrainMutex = Mutex()
    /** Set when the signer can't silently decrypt (Amber background signing not
     *  granted). The drain stops instead of firing an Intent per message; the UI
     *  surfaces this so the user can enable auto-signing in Amber. */
    internal val _decryptBlocked = MutableStateFlow(false)
    val decryptBlocked: StateFlow<Boolean> = _decryptBlocked.asStateFlow()
    internal var lastBlockedSize = -1
    internal var switchGeneration = 0
    internal var lastExternalFetchTimestamp = 0L
    internal var hasStarted = false
    internal var saveJob: Job? = null

    /**
     * The account (hex pubkey) whose conversations are in memory, and so the
     * only cache file they may be written to. Set when they are loaded, not
     * read at write time: a write landing after a switch used to put one
     * account's DMs into the other's file.
     */
    @Volatile internal var loadedCacheKey: String? = null

    init {
        // Follow account switches, as iOS DMService does. Skips setup's first
        // account ("" → X) and anything before the inbox has started.
        scope.launch {
            configStore.accountSwitches.collect { hex ->
                // A switch to no account (reset, or an account that can't be
                // decoded) leaves the inbox alone: there is no one to load.
                if (hex.isNotEmpty() && hasStarted && hex != loadedCacheKey) switchAccount()
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Lifecycle
    // ══════════════════════════════════════════════════════════════════

    /** Start listening once (idempotent). Used from app lifecycle hooks. */
    fun startIfNeeded() {
        if (hasStarted) return
        startListening()
    }

    fun syncOnForeground() {
        // Live sockets may have been suspended/dropped while backgrounded.
        if (liveExternalClients.isEmpty()) {
            connectToExternalDMRelays(switchGeneration)
        } else {
            liveExternalClients.forEach { it.resetReconnect() }
        }
        fetchFromExternalRelays()
    }

    fun refresh() {
        // Do NOT tear down + reconnect the local /chat socket here: that re-runs
        // NIP-42 AUTH (an Amber prompt) on every pull, and wiping conversations/
        // seen-set forces re-decryption (more prompts). The local sockets are live
        // subscriptions; a refresh just needs a network catch-up.
        if (!hasStarted) {
            startListening()
        } else if (liveExternalClients.isEmpty()) {
            connectToExternalDMRelays(switchGeneration)
        }
        fetchFromExternalRelays()
    }

    /**
     * Drain the queued inbound DMs, decrypting them ONE AT A TIME. Call this when
     * a DM screen becomes visible. No-op in local-key mode (those decrypt eagerly
     * on arrival). The drain mutex guarantees a single drainer even if the inbox
     * and a thread both request it.
     */
    suspend fun decryptPending() {
        if (!isAmberMode()) return
        decryptDrainMutex.withLock {
            // If we already blocked and nothing new has queued since, don't retry —
            // this stops the UI's pendingDecryptCount collector from spinning the
            // drain (and re-hitting the signer) in a tight loop while blocked.
            if (_decryptBlocked.value && pendingDecryptQueue.size == lastBlockedSize) return@withLock
            _decryptBlocked.value = false

            while (true) {
                val ev = pendingDecryptQueue.poll() ?: break
                val id = ev["id"]?.jsonPrimitive?.contentOrNull
                if (id == null) { _pendingDecryptCount.value = pendingDecryptQueue.size; continue }
                queuedDecryptIds.remove(id)
                if (!seenGiftWrapIds.add(id)) { _pendingDecryptCount.value = pendingDecryptQueue.size; continue }
                val gen = switchGeneration
                val processed = when (ev["kind"]?.jsonPrimitive?.intOrNull) {
                    1059 -> decryptGiftWrap(ev, id, gen)
                    4 -> decryptNip04(ev, id, gen)
                    else -> true
                }
                if (!processed) {
                    // Signer can't silently decrypt right now. Put the item back,
                    // un-claim it, flag blocked, and STOP — do NOT machine-gun the
                    // signer with an approval Intent per remaining message.
                    seenGiftWrapIds.remove(id)
                    queuedDecryptIds.add(id)
                    pendingDecryptQueue.add(ev)
                    lastBlockedSize = pendingDecryptQueue.size
                    _decryptBlocked.value = true
                    _pendingDecryptCount.value = pendingDecryptQueue.size
                    if (BuildConfig.DEBUG) Log.w(TAG, "DBG: drain blocked — signer silent-decrypt unavailable, ${pendingDecryptQueue.size} pending")
                    return@withLock
                }
                _pendingDecryptCount.value = pendingDecryptQueue.size
            }
            _pendingDecryptCount.value = pendingDecryptQueue.size
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Sending DMs
    // ══════════════════════════════════════════════════════════════════

    /**
     * Send a DM using NIP-17 (default) or NIP-04 (legacy).
     */
    /**
     * Sends a DM. Throws when the message could not be built (no key, a
     * signer that refused, encryption failed) so the screen can show iOS's
     * "Failed to Send" alert and hand the text back; nothing was published
     * then. Once publishing starts, relay failures are only logged.
     */
    suspend fun sendDM(
        content: String,
        recipientHexPubkey: String,
        useNIP04: Boolean = false,
    ) {
        if (useNIP04) {
            sendNIP04DM(content, recipientHexPubkey)
        } else {
            sendNIP17DM(content, recipientHexPubkey)
        }
    }

    @Volatile internal var backfillRunning = false

    // ══════════════════════════════════════════════════════════════════
    // ViewModel convenience methods
    // ══════════════════════════════════════════════════════════════════

    /** Get messages for a specific conversation as a StateFlow. */
    fun messagesForConversation(pubkey: String): StateFlow<List<DMMessage>> {
        return _conversations.map { convos ->
            convos.firstOrNull { it.id == pubkey }?.messages ?: emptyList()
        }.stateIn(scope, SharingStarted.WhileSubscribed(5000), emptyList())
    }

    /** Start listening and load cached conversations. */
    fun loadConversations() {
        startListening()
    }

    /** Alias for markRead, used by DMThreadViewModel. */
    fun markConversationRead(pubkey: String) = markRead(pubkey)

    /** Alias for sendDM, used by DMThreadViewModel. */
    suspend fun sendMessage(recipientPubkey: String, content: String, useNIP04: Boolean = false) {
        sendDM(content, recipientPubkey, useNIP04)
    }

    fun markAllAsRead() {
        _conversations.value = _conversations.value.map { it.copy(unreadCount = 0) }
        saveCachedConversations()
    }

}
