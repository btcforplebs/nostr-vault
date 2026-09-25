package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.CredentialStore
import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.relay.HavenBridge
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
    private val configStore: ConfigStore,
    private val credentialStore: CredentialStore,
    private val nostrService: NostrService,
    private val amberSignerService: AmberSignerService,
) {
    companion object {
        private const val TAG = "DMService"
        private const val EXTERNAL_FETCH_MAX_RELAYS = 15
        private const val LIVE_EXTERNAL_MAX_RELAYS = 8
        private const val PERIODIC_SYNC_INTERVAL_MS = 5 * 60 * 1000L // 5 minutes
        private const val FIRE_AND_FORGET_FLUSH_MS = 300L
        private const val FIRE_AND_FORGET_TIMEOUT_MS = 3_000L
        private const val AUTH_TIMEOUT_MS = 5_000L
        private const val EXTERNAL_FETCH_OVERLAP_MS = 60 * 60 * 1000L // 1 hour overlap
        private const val OPTIMISTIC_DEDUP_THRESHOLD_MS = 30_000L
        private const val MAX_INJECTED_DM_IDS = 5_000
        private const val CACHE_SAVE_DEBOUNCE_MS = 500L
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val json = Json { ignoreUnknownKeys = true }

    // ── Observable state ──────────────────────────────────────────────

    private val _conversations = MutableStateFlow<List<DMConversation>>(emptyList())
    val conversations: StateFlow<List<DMConversation>> = _conversations.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    /** Count of inbound DMs queued for (Amber) decryption but not yet processed.
     *  Drives an optional "N pending" indicator; drained by [decryptPending]. */
    private val _pendingDecryptCount = MutableStateFlow(0)
    val pendingDecryptCount: StateFlow<Int> = _pendingDecryptCount.asStateFlow()

    val totalUnreadCount: Int
        get() = _conversations.value.sumOf { it.unreadCount }

    val totalUnreadCountFlow: StateFlow<Int> = _conversations
        .map { convos -> convos.sumOf { it.unreadCount } }
        .stateIn(scope, SharingStarted.WhileSubscribed(5_000), 0)

    // ── Internal state ────────────────────────────────────────────────

    private var inboxClient: WebSocketClient? = null     // NIP-17 /chat relay
    private var nip04Client: WebSocketClient? = null     // NIP-04 /inbox relay
    private var chatInjectionClient: WebSocketClient? = null
    private var inboxInjectionClient: WebSocketClient? = null
    /** Persistent live subscriptions to the user's PUBLIC DM relays. */
    private val liveExternalClients = mutableListOf<WebSocketClient>()
    private var periodicSyncJob: Job? = null
    private var chatResubJob: Job? = null

    private val seenGiftWrapIds = ConcurrentHashMap.newKeySet<String>()
    private val injectedDmIds = ConcurrentHashMap.newKeySet<String>()

    // ── Lazy (Amber) decryption queue ─────────────────────────────────
    // In Amber mode we must NOT decrypt inbound DMs in the background: every
    // decrypt is a remote-signer round-trip funneled through one app-wide lock,
    // so a backlog would hammer Amber and stall all other signing. Instead we
    // queue raw wraps and drain them sequentially, on demand, only while a DM
    // screen is open. (Pattern borrowed from dark-wisp's pendingGiftWraps.)
    private val pendingDecryptQueue = java.util.concurrent.ConcurrentLinkedQueue<JsonObject>()
    private val queuedDecryptIds = ConcurrentHashMap.newKeySet<String>()
    private val decryptDrainMutex = Mutex()
    /** Set when the signer can't silently decrypt (Amber background signing not
     *  granted). The drain stops instead of firing an Intent per message; the UI
     *  surfaces this so the user can enable auto-signing in Amber. */
    private val _decryptBlocked = MutableStateFlow(false)
    val decryptBlocked: StateFlow<Boolean> = _decryptBlocked.asStateFlow()
    private var lastBlockedSize = -1
    private var switchGeneration = 0
    private var lastExternalFetchTimestamp = 0L
    private var hasStarted = false
    private var saveJob: Job? = null

    // ══════════════════════════════════════════════════════════════════
    // Lifecycle
    // ══════════════════════════════════════════════════════════════════

    /** Start listening once (idempotent). Used from app lifecycle hooks. */
    fun startIfNeeded() {
        if (hasStarted) return
        startListening()
    }

    fun startListening() {
        hasStarted = true
        switchGeneration++
        val generation = switchGeneration

        // Drop any pending decrypts queued for a previous account/generation.
        pendingDecryptQueue.clear()
        queuedDecryptIds.clear()
        _pendingDecryptCount.value = 0
        _decryptBlocked.value = false
        lastBlockedSize = -1
        chatResubJob?.cancel()

        loadCachedConversations()
        connectToLocalChatRelay(generation)
        connectToLocalNip04Relay(generation)
        // Persistent subscriptions to our public DM relays so inbound replies
        // arrive in real-time (the local sockets only see DMs already in the DB).
        connectToExternalDMRelays(generation)
        startPeriodicSync()
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

    // ══════════════════════════════════════════════════════════════════
    // Local relay connections
    // ══════════════════════════════════════════════════════════════════

    private fun connectToLocalChatRelay(generation: Int) {
        val config = configStore.config.value
        val chatUrl = config.localRelayURL("chat") ?: return

        inboxClient?.disconnect()
        val client = WebSocketClient(url = chatUrl, scope = scope, trustLocalhost = true)
        inboxClient = client

        scope.launch {
            client.connectionState.collect { state ->
                if (state == WebSocketClient.ConnectionState.CONNECTED) {
                    // NIP-42 AUTH will be needed — handled via AUTH message.
                    // An external relay (e.g. Citrine) may never challenge,
                    // so the AUTH-OK that normally sends the subscription
                    // never comes; subscribe straight away there instead.
                    if (config.useExternalRelay) sendChatNip17Req()
                }
            }
        }

        scope.launch {
            client.messages.collect { msg ->
                if (switchGeneration != generation) return@collect
                launch(Dispatchers.Default) {
                    handleChatRelayMessage(msg, generation)
                }
            }
        }

        client.connect()
    }

    private fun connectToLocalNip04Relay(generation: Int) {
        val config = configStore.config.value
        val inboxUrl = config.localInboxURL ?: return

        nip04Client?.disconnect()
        val client = WebSocketClient(url = inboxUrl, scope = scope, trustLocalhost = true)
        nip04Client = client

        scope.launch {
            client.connectionState.collect { state ->
                if (state == WebSocketClient.ConnectionState.CONNECTED) {
                    subscribeToNip04(client)
                }
            }
        }

        scope.launch {
            client.messages.collect { msg ->
                if (switchGeneration != generation) return@collect
                launch(Dispatchers.Default) {
                    handleNip04RelayMessage(msg, generation)
                }
            }
        }

        client.connect()
    }

    private fun subscribeToNip04(client: WebSocketClient) {
        val ownerHex = nostrService.activeHexPubkey
        val subId = "dm-nip04"
        Log.w(TAG, "DBG: subscribeToNip04 ownerHex=${ownerHex.take(12)} amber=${isAmberMode()}")

        // Incoming NIP-04 DMs
        val inFilter = """{"kinds":[4],"#p":["$ownerHex"]}"""
        client.send("[\"REQ\",\"$subId-in\",$inFilter]")

        // Outgoing NIP-04 DMs (sent by us)
        val outFilter = """{"kinds":[4],"authors":["$ownerHex"]}"""
        client.send("[\"REQ\",\"$subId-out\",$outFilter]")
    }

    // ══════════════════════════════════════════════════════════════════
    // Message handling
    // ══════════════════════════════════════════════════════════════════

    private fun handleChatRelayMessage(message: String, generation: Int) {
        try {
            val parsed = json.parseToJsonElement(message).jsonArray
            if (parsed.isEmpty()) return
            val type = parsed[0].jsonPrimitive.contentOrNull ?: return

            if (type != "EVENT") Log.w(TAG, "DBG: /chat recv type=$type")
            when (type) {
                "AUTH" -> handleAuthChallenge(parsed, inboxClient)
                "OK" -> {
                    // Response to our NIP-42 AUTH event. The /chat relay requires
                    // AUTH *before* it will accept a REQ, so the kind-1059
                    // subscription must be sent here, once AUTH succeeds — NOT on
                    // EOSE (an EOSE only ever arrives in response to a REQ, so the
                    // old EOSE-gated subscribe never fired and no DMs loaded).
                    // Re-sending on every successful OK is idempotent (same subId
                    // replaces the subscription) and re-arms it after a reconnect.
                    val success = parsed.getOrNull(2)?.jsonPrimitive?.booleanOrNull ?: false
                    val reason = parsed.getOrNull(3)?.jsonPrimitive?.contentOrNull
                    Log.w(TAG, "DBG: /chat OK success=$success reason=$reason")
                    if (success) sendChatNip17Req()
                }
                "CLOSED" -> {
                    // The /chat relay's RejectFilter is [MustAuth, MustBeInWotToQuery].
                    // Its Web of Trust takes ~60s to build on launch, and until then
                    // every query — even the owner's — is rejected with CLOSED. The
                    // subscription is sent once on AUTH-OK and never retried, so a
                    // cold start loses all NIP-17 (gift-wrapped) delivery until the
                    // next reconnect happens to land after WoT is ready. Re-arm the
                    // sub on a backoff so gift wraps start flowing once WoT warms up.
                    val subId = parsed.getOrNull(1)?.jsonPrimitive?.contentOrNull
                    val reason = parsed.getOrNull(2)?.jsonPrimitive?.contentOrNull
                    Log.w(TAG, "DBG: /chat CLOSED sub=$subId reason=$reason")
                    if (subId == "dm-nip17") scheduleChatResubscribe(generation)
                }
                "EVENT" -> {
                    if (parsed.size < 3) return
                    val eventObj = parsed[2].jsonObject
                    val kind = eventObj["kind"]?.jsonPrimitive?.intOrNull ?: return

                    if (kind == 1059) {
                        // NIP-17 gift-wrapped DM
                        scope.launch {
                            handleIncomingGiftWrap(eventObj, generation)
                        }
                    }
                }
                "EOSE" -> {
                    // EOSE only arrives if the REQ was ACCEPTED — WoT is ready and
                    // stored gift wraps have streamed. Stop any resubscribe backoff.
                    chatResubJob?.cancel()
                    _isLoading.value = false
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Chat relay message parse error: ${e.message}")
        }
    }

    /** (Re)send the kind-1059 subscription on the authed /chat socket. */
    private fun sendChatNip17Req() {
        val ownerHex = nostrService.activeHexPubkey
        if (ownerHex.isBlank()) return
        inboxClient?.send("[\"REQ\",\"dm-nip17\",{\"kinds\":[1059],\"#p\":[\"$ownerHex\"]}]")
    }

    /**
     * Retry the /chat kind-1059 subscription on a backoff while the relay's Web of
     * Trust is still warming up (it rejects queries with CLOSED until ~60s after
     * launch). Cancelled as soon as an EOSE confirms the sub was accepted.
     */
    private fun scheduleChatResubscribe(generation: Int) {
        if (chatResubJob?.isActive == true) return
        chatResubJob = scope.launch {
            var attempt = 0
            while (isActive && switchGeneration == generation && attempt < 12) {
                delay(12_000)
                if (switchGeneration != generation) return@launch
                attempt++
                Log.w(TAG, "DBG: /chat re-subscribe dm-nip17 attempt=$attempt")
                sendChatNip17Req()
            }
        }
    }

    private fun handleNip04RelayMessage(message: String, generation: Int) {
        try {
            val parsed = json.parseToJsonElement(message).jsonArray
            if (parsed.isEmpty()) return
            val type = parsed[0].jsonPrimitive.contentOrNull ?: return

            when (type) {
                "EVENT" -> {
                    if (parsed.size < 3) return
                    val eventObj = parsed[2].jsonObject
                    val kind = eventObj["kind"]?.jsonPrimitive?.intOrNull ?: return
                    Log.w(TAG, "DBG: /inbox EVENT kind=$kind")

                    if (kind == 4) {
                        scope.launch {
                            handleIncomingNIP04(eventObj, generation)
                        }
                    }
                }
                else -> Log.w(TAG, "DBG: /inbox recv type=$type")
            }
        } catch (e: Exception) {
            Log.w(TAG, "NIP-04 relay message parse error: ${e.message}")
        }
    }

    private suspend fun handleIncomingGiftWrap(eventObj: JsonObject, generation: Int) {
        val eventId = eventObj["id"]?.jsonPrimitive?.contentOrNull ?: return
        if (switchGeneration != generation) return
        if (seenGiftWrapIds.contains(eventId)) { Log.w(TAG, "DBG: giftwrap ${eventId.take(8)} skipped (already seen)"); return }

        // Amber mode: queue instead of decrypting now (see pendingDecryptQueue).
        if (isAmberMode()) { enqueuePendingDecrypt(eventObj, eventId); return }

        // Local key: decrypt eagerly — cheap, no signer IPC or prompts.
        if (!seenGiftWrapIds.add(eventId)) return
        decryptGiftWrap(eventObj, eventId, generation)
    }

    /**
     * Decrypts a kind-1059 gift wrap and folds it into the conversation list.
     * Caller has already claimed [eventId] in seenGiftWrapIds.
     * @return true if processed (decrypted, or definitively undecryptable data);
     *   false ONLY if the signer was unavailable for a silent decrypt (retryable).
     */
    private suspend fun decryptGiftWrap(eventObj: JsonObject, eventId: String, generation: Int): Boolean {
        if (switchGeneration != generation) return true
        return withContext(Dispatchers.IO) {
            try {
                val giftWrapContent = eventObj["content"]?.jsonPrimitive?.contentOrNull ?: return@withContext true
                val giftWrapPubkey = eventObj["pubkey"]?.jsonPrimitive?.contentOrNull ?: return@withContext true
                Log.w(TAG, "DBG: giftwrap ${eventId.take(8)} decrypting (amber=${isAmberMode()})")

                val rumorJson = if (isAmberMode()) {
                    // Gift wrap → seal → rumor is TWO NIP-44 layers; Amber must
                    // decrypt both. silentOnly: a backlog drain must never fall back
                    // to an interactive Intent per message (floods the signer).
                    NIP17Service.unwrapGiftWrappedDMWithAmber(
                        giftWrapContent, giftWrapPubkey, amberSignerService, silentOnly = true,
                    ) ?: run {
                        Log.w(TAG, "DBG: giftwrap ${eventId.take(8)} silent decrypt unavailable")
                        return@withContext false // signer can't silently decrypt → retryable
                    }
                } else {
                    val recipientPrivkey = resolvePrivateKey() ?: return@withContext true
                    NIP17Service.unwrapGiftWrappedDM(giftWrapContent, giftWrapPubkey, recipientPrivkey)
                        ?: run { Log.w(TAG, "DBG: giftwrap ${eventId.take(8)} decrypt returned NULL"); return@withContext true }
                }

                // Parse the rumor JSON to extract sender, content, timestamp, tags
                val rumorObj = json.parseToJsonElement(rumorJson).jsonObject
                val senderPubkey = rumorObj["pubkey"]?.jsonPrimitive?.contentOrNull ?: return@withContext true
                val content = rumorObj["content"]?.jsonPrimitive?.contentOrNull ?: return@withContext true
                val timestamp = rumorObj["created_at"]?.jsonPrimitive?.longOrNull ?: return@withContext true
                val rumorTags = rumorObj["tags"]?.jsonArray?.map { t ->
                    t.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" }
                } ?: emptyList()
                val isFromMe = senderPubkey == nostrService.activeHexPubkey

                // Determine counterparty from rumor tags
                val counterparty = if (isFromMe) {
                    rumorTags.firstOrNull { it.size >= 2 && it[0] == "p" }?.get(1) ?: return@withContext true
                } else {
                    senderPubkey
                }

                val message = DMMessage(
                    id = eventId,
                    content = content,
                    timestamp = timestamp,
                    senderPubkey = senderPubkey,
                    isFromMe = isFromMe,
                    isNIP04 = false,
                )

                withContext(Dispatchers.Main.immediate) {
                    addMessageToConversation(counterparty, message)
                }
                true
            } catch (e: Exception) {
                Log.w(TAG, "Gift wrap unwrap failed: ${e.message}")
                true // bad data — don't requeue
            }
        }
    }

    private suspend fun handleIncomingNIP04(eventObj: JsonObject, generation: Int) {
        val eventId = eventObj["id"]?.jsonPrimitive?.contentOrNull ?: return
        if (switchGeneration != generation) return
        if (seenGiftWrapIds.contains(eventId)) { Log.w(TAG, "DBG: nip04 ${eventId.take(8)} skipped (already seen)"); return }

        // Amber mode: queue instead of decrypting now (see pendingDecryptQueue).
        if (isAmberMode()) { enqueuePendingDecrypt(eventObj, eventId); return }

        // Local key: decrypt eagerly — cheap, no signer IPC or prompts.
        if (!seenGiftWrapIds.add(eventId)) return
        decryptNip04(eventObj, eventId, generation)
    }

    /**
     * Decrypts a kind-4 NIP-04 DM and folds it into the conversation list.
     * Caller has already claimed [eventId] in seenGiftWrapIds.
     * @return true if processed; false ONLY if the signer was unavailable for a
     *   silent decrypt (retryable).
     */
    private suspend fun decryptNip04(eventObj: JsonObject, eventId: String, generation: Int): Boolean {
        if (switchGeneration != generation) return true
        return withContext(Dispatchers.IO) {
            try {
                val pubkey = eventObj["pubkey"]?.jsonPrimitive?.contentOrNull ?: return@withContext true
                val content = eventObj["content"]?.jsonPrimitive?.contentOrNull ?: return@withContext true
                val createdAt = eventObj["created_at"]?.jsonPrimitive?.longOrNull ?: return@withContext true
                val tags = eventObj["tags"]?.jsonArray?.map { t ->
                    t.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" }
                } ?: emptyList()

                val ownerHex = nostrService.activeHexPubkey
                val isFromMe = pubkey == ownerHex
                val counterparty = if (isFromMe) {
                    tags.firstOrNull { it.size >= 2 && it[0] == "p" }?.get(1) ?: return@withContext true
                } else {
                    pubkey
                }
                Log.w(TAG, "DBG: nip04 ${eventId.take(8)} fromMe=$isFromMe cp=${counterparty.take(12)} decrypting (amber=${isAmberMode()})")

                // Decrypt (Amber or local key). silentOnly for the Amber path — a
                // backlog drain must not launch an interactive Intent per message.
                val plaintext = if (isAmberMode()) {
                    amberSignerService.nip04Decrypt(content, counterparty, silentOnly = true)
                        ?: run {
                            Log.w(TAG, "DBG: nip04 ${eventId.take(8)} silent decrypt unavailable")
                            return@withContext false // retryable
                        }
                } else {
                    val privkey = resolvePrivateKey() ?: return@withContext true
                    NIP04Service.decrypt(content, counterparty, privkey)
                        ?: run { Log.w(TAG, "DBG: nip04 ${eventId.take(8)} decrypt returned NULL"); return@withContext true }
                }
                Log.w(TAG, "DBG: nip04 ${eventId.take(8)} decrypted len=${plaintext.length}")

                val message = DMMessage(
                    id = eventId,
                    content = plaintext,
                    timestamp = createdAt,
                    senderPubkey = pubkey,
                    isFromMe = isFromMe,
                    isNIP04 = true,
                )

                withContext(Dispatchers.Main.immediate) {
                    addMessageToConversation(counterparty, message)
                }
                true
            } catch (e: Exception) {
                Log.w(TAG, "NIP-04 decrypt failed: ${e.message}")
                true // bad data — don't requeue
            }
        }
    }

    /** Queue a raw inbound DM event for on-demand (Amber) decryption. */
    private fun enqueuePendingDecrypt(eventObj: JsonObject, eventId: String) {
        if (seenGiftWrapIds.contains(eventId)) return
        if (!queuedDecryptIds.add(eventId)) return
        pendingDecryptQueue.add(eventObj)
        _pendingDecryptCount.value = pendingDecryptQueue.size
        Log.w(TAG, "DBG: queued ${eventId.take(8)} for decrypt (pending=${pendingDecryptQueue.size})")
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
                    Log.w(TAG, "DBG: drain blocked — signer silent-decrypt unavailable, ${pendingDecryptQueue.size} pending")
                    return@withLock
                }
                _pendingDecryptCount.value = pendingDecryptQueue.size
            }
            _pendingDecryptCount.value = pendingDecryptQueue.size
        }
    }

    private fun addMessageToConversation(counterparty: String, message: DMMessage) {
        val current = _conversations.value.toMutableList()
        val existingIndex = current.indexOfFirst { it.id == counterparty }

        if (existingIndex >= 0) {
            val conv = current[existingIndex]
            // Already have this exact event — nothing to do.
            if (conv.messages.any { it.id == message.id }) return
            // Optimistic-send dedup: a message WE sent echoes back from the relay
            // with a real id; collapse it onto the optimistic copy. Gate on
            // isFromMe — applying this to inbound messages dropped distinct DMs
            // with identical short content (e.g. "ok"), so they were never cached
            // and got re-decrypted (re-prompting Amber) on every refresh.
            val isDuplicate = message.isFromMe && conv.messages.any { existing ->
                existing.isFromMe &&
                    existing.content == message.content &&
                    kotlin.math.abs(existing.timestamp - message.timestamp) < OPTIMISTIC_DEDUP_THRESHOLD_MS / 1000
            }
            if (isDuplicate) return

            val updatedMessages = (conv.messages + message).sortedBy { it.timestamp }
            val unread = if (message.isFromMe) conv.unreadCount else conv.unreadCount + 1
            current[existingIndex] = conv.copy(
                messages = updatedMessages,
                unreadCount = unread,
            )
        } else {
            current.add(
                DMConversation(
                    id = counterparty,
                    messages = listOf(message),
                    unreadCount = if (message.isFromMe) 0 else 1,
                )
            )
        }

        // Sort by most recent
        current.sortByDescending { it.lastMessage?.timestamp ?: 0L }
        _conversations.value = current
        Log.w(TAG, "DBG: addMessageToConversation cp=${counterparty.take(12)} → convos=${current.size}")
        saveCachedConversations()
    }

    // ══════════════════════════════════════════════════════════════════
    // Sending DMs
    // ══════════════════════════════════════════════════════════════════

    /**
     * Send a DM using NIP-17 (default) or NIP-04 (legacy).
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

    private suspend fun sendNIP17DM(content: String, recipientHexPubkey: String) {
        val generation = switchGeneration

        // Optimistic UI update
        val optimisticId = UUID.randomUUID().toString()
        val optimisticMessage = DMMessage(
            id = optimisticId,
            content = content,
            timestamp = System.currentTimeMillis() / 1000,
            senderPubkey = nostrService.activeHexPubkey,
            isFromMe = true,
            isNIP04 = false,
        )
        withContext(Dispatchers.Main.immediate) {
            addMessageToConversation(recipientHexPubkey, optimisticMessage)
        }

        // Create gift wraps in background
        withContext(Dispatchers.IO) {
            try {
                val ownHexPubkey = nostrService.activeHexPubkey

                val recipientEvent: String
                val selfEvent: String

                if (isAmberMode()) {
                    // Amber mode: delegate NIP-44 encrypt + seal signing to Amber
                    recipientEvent = NIP17Service.createGiftWrappedDMWithAmber(
                        content = content,
                        senderPubkey = ownHexPubkey,
                        recipientPubkey = recipientHexPubkey,
                        amberSignerService = amberSignerService,
                    ) ?: throw Exception("Failed to create recipient wrap via Amber")
                    selfEvent = NIP17Service.createGiftWrappedDMWithAmber(
                        content = content,
                        senderPubkey = ownHexPubkey,
                        recipientPubkey = ownHexPubkey,
                        amberSignerService = amberSignerService,
                    ) ?: throw Exception("Failed to create self wrap via Amber")
                } else {
                    val privkey = resolvePrivateKey() ?: throw Exception("No private key")

                    // Create gift wraps concurrently
                    val recipientWrap = async {
                        NIP17Service.createGiftWrappedDM(
                            content = content,
                            senderSecretKey = privkey,
                            senderPubkey = ownHexPubkey,
                            recipientPubkey = recipientHexPubkey,
                        )
                    }
                    val selfWrap = async {
                        NIP17Service.createGiftWrappedDM(
                            content = content,
                            senderSecretKey = privkey,
                            senderPubkey = ownHexPubkey,
                            recipientPubkey = ownHexPubkey,
                        )
                    }

                    recipientEvent = recipientWrap.await() ?: throw Exception("Failed to create recipient wrap")
                    selfEvent = selfWrap.await() ?: throw Exception("Failed to create self wrap")
                }

                if (switchGeneration != generation) return@withContext

                // Pre-mark our own self-copy gift wrap as seen. It is addressed to
                // us (kind 1059, #p = self) so it echoes back through every DM
                // subscription; without this it would be decrypted again — a wasted
                // Amber round-trip per sent message for a message we already hold
                // optimistically. (Pattern borrowed from dark-wisp markGiftWrapSeen.)
                runCatching {
                    json.parseToJsonElement(selfEvent).jsonObject["id"]
                        ?.jsonPrimitive?.contentOrNull
                }.getOrNull()?.let { seenGiftWrapIds.add(it) }

                // Publish to local /chat relay
                val config = configStore.config.value
                val chatUrl = config.localRelayURL("chat")
                chatUrl?.let {
                    inboxClient?.send("[\"EVENT\",$recipientEvent]")
                    inboxClient?.send("[\"EVENT\",$selfEvent]")
                }

                // Fetch recipient's DM relays and publish
                val recipientRelays = fetchRecipientDMRelays(recipientHexPubkey)
                for (relayUrl in recipientRelays) {
                    fireAndForgetPublish(recipientEvent, relayUrl)
                }

                // Publish self copy to own DM relays. Use the same fallback-aware
                // resolver as the recipient path (kind 10050 → 10002 → fetch-and-wait
                // → blastr); a bare dmRelayLists lookup returns empty when our own DM
                // relay list isn't cached yet, stranding the self-copy on the local
                // relay so our OTHER devices never see the message we sent.
                val ownRelays = fetchRecipientDMRelays(ownHexPubkey)
                for (relayUrl in ownRelays) {
                    fireAndForgetPublish(selfEvent, relayUrl)
                }
            } catch (e: Exception) {
                Log.e(TAG, "NIP-17 send failed: ${e.message}")
            }
        }
    }

    private suspend fun sendNIP04DM(content: String, recipientHexPubkey: String) {
        val generation = switchGeneration

        withContext(Dispatchers.IO) {
            try {
                val encrypted = if (isAmberMode()) {
                    amberSignerService.nip04Encrypt(content, recipientHexPubkey)
                        ?: throw Exception("Amber encryption failed")
                } else {
                    val privkey = resolvePrivateKey() ?: throw Exception("No private key")
                    NIP04Service.encrypt(content, recipientHexPubkey, privkey)
                        ?: throw Exception("Encryption failed")
                }

                val tags = listOf(listOf("p", recipientHexPubkey))
                // Use the async, signing-mode-aware path so NIP-04 sends work under
                // Amber / NIP-46 (the sync signEvent only handles a local key).
                val event = nostrService.signEventAsync(kind = 4, content = encrypted, tags = tags)
                    ?: throw Exception("Signing failed")

                if (switchGeneration != generation) return@withContext

                // Optimistic UI
                val message = DMMessage(
                    id = event.id,
                    content = content,
                    timestamp = event.createdAt,
                    senderPubkey = event.pubkey,
                    isFromMe = true,
                    isNIP04 = true,
                )
                withContext(Dispatchers.Main.immediate) {
                    addMessageToConversation(recipientHexPubkey, message)
                }

                // Publish to local relay
                val eventJson = serializeEvent(event)
                val config = configStore.config.value
                config.localInboxURL?.let {
                    nip04Client?.send("[\"EVENT\",$eventJson]")
                }

                // Fire-and-forget to recipient's relays
                val recipientRelays = fetchRecipientDMRelays(recipientHexPubkey)
                for (relayUrl in recipientRelays) {
                    fireAndForgetPublish(eventJson, relayUrl)
                }

                // Also publish to our OWN relays so other devices on this account can
                // fetch the message we just sent. A kind-4 event carries no self-copy,
                // so without this the sent message is stranded on the local relay.
                val ownHexPubkey = nostrService.activeHexPubkey
                val ownRelays = fetchRecipientDMRelays(ownHexPubkey)
                for (relayUrl in ownRelays) {
                    if (relayUrl in recipientRelays) continue
                    fireAndForgetPublish(eventJson, relayUrl)
                }
            } catch (e: Exception) {
                Log.e(TAG, "NIP-04 send failed: ${e.message}")
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // External relay fetching
    // ══════════════════════════════════════════════════════════════════

    fun fetchFromExternalRelays() {
        scope.launch(Dispatchers.IO) {
            val ownerHex = nostrService.activeHexPubkey
            val dmRelays = nostrService.dmRelayLists.value[ownerHex] ?: emptyList()
            val inboxRelays = nostrService.relayLists.value[ownerHex] ?: emptyList()
            // Fall back to configured DM relays + blastr so a fetch still happens
            // when our own kind 10050/10002 isn't cached yet (e.g. a fresh setup
            // or an account that never published a relay list) — otherwise
            // pull-to-refresh queried zero relays and nothing ever loaded.
            val configured = configStore.config.value.dmRelays
            val blastr = configStore.config.value.activeBlastrRelays
            val allRelays = (dmRelays + inboxRelays + configured + blastr)
                .distinct()
                .filter { !it.contains("localhost") && !it.contains("127.0.0.1") }
                .take(EXTERNAL_FETCH_MAX_RELAYS)

            if (allRelays.isEmpty()) return@launch

            val since = if (lastExternalFetchTimestamp > 0) {
                lastExternalFetchTimestamp / 1000 - (EXTERNAL_FETCH_OVERLAP_MS / 1000)
            } else {
                System.currentTimeMillis() / 1000 - (7 * 24 * 60 * 60) // 7 days
            }

            val generation = switchGeneration

            for (relayUrl in allRelays) {
                launch {
                    try {
                        val client = WebSocketClient(url = relayUrl, scope = scope)
                        val subId = "dm-ext-${UUID.randomUUID().toString().take(8)}"

                        launch {
                            client.messages.collect { msg ->
                                if (switchGeneration != generation) return@collect
                                launch(Dispatchers.Default) {
                                    handleExternalDmMessage(msg, generation)
                                }
                            }
                        }

                        client.connect()

                        // NIP-17 (kind 1059)
                        val nip17Filter = """{"kinds":[1059],"#p":["$ownerHex"],"since":$since}"""
                        client.send("[\"REQ\",\"$subId-17\",$nip17Filter]")

                        // NIP-04 incoming (kind 4)
                        val nip04InFilter = """{"kinds":[4],"#p":["$ownerHex"],"since":$since}"""
                        client.send("[\"REQ\",\"$subId-04in\",$nip04InFilter]")

                        // NIP-04 outgoing (kind 4)
                        val nip04OutFilter = """{"kinds":[4],"authors":["$ownerHex"],"since":$since}"""
                        client.send("[\"REQ\",\"$subId-04out\",$nip04OutFilter]")

                        delay(10_000)
                        client.disconnect()
                    } catch (e: Exception) {
                        Log.w(TAG, "External DM fetch from $relayUrl failed: ${e.message}")
                    }
                }
            }

            lastExternalFetchTimestamp = System.currentTimeMillis()
        }
    }

    private suspend fun handleExternalDmMessage(message: String, generation: Int) {
        try {
            val parsed = json.parseToJsonElement(message).jsonArray
            if (parsed.size < 3 || parsed[0].jsonPrimitive.contentOrNull != "EVENT") return

            val eventObj = parsed[2].jsonObject
            val kind = eventObj["kind"]?.jsonPrimitive?.intOrNull ?: return

            when (kind) {
                1059 -> handleIncomingGiftWrap(eventObj, generation)
                4 -> handleIncomingNIP04(eventObj, generation)
            }
        } catch (_: Exception) {}
    }

    // ══════════════════════════════════════════════════════════════════
    // Live external DM subscription (real-time inbound from public relays)
    // ══════════════════════════════════════════════════════════════════

    /**
     * The PUBLIC relays to keep persistent DM subscriptions on: the relays we
     * advertise in our kind 10050 (where senders deliver to us), plus our cached
     * NIP-65 inbox relays and blastr relays as fallbacks. Loopback excluded.
     */
    private fun liveExternalRelaySet(ownerHex: String): List<String> {
        val advertised = nostrService.dmRelayLists.value[ownerHex] ?: emptyList()
        val inbox = nostrService.relayLists.value[ownerHex] ?: emptyList()
        val configured = configStore.config.value.dmRelays
        val blastr = configStore.config.value.activeBlastrRelays
        return (advertised + configured + inbox + blastr)
            .map { it.trim() }
            .filter { it.isNotEmpty() && !it.contains("localhost") && !it.contains("127.0.0.1") }
            .distinct()
            .take(LIVE_EXTERNAL_MAX_RELAYS)
    }

    /**
     * Opens persistent subscriptions to our public DM relays for both NIP-17
     * (kind 1059) and NIP-04 (kind 4) inbound DMs. The underlying WebSocketClient
     * auto-reconnects with backoff; we (re)send the REQ filters on every CONNECTED.
     */
    private fun connectToExternalDMRelays(generation: Int) {
        // Tear down any previous live subscriptions first.
        liveExternalClients.forEach { it.disconnect() }
        liveExternalClients.clear()

        val ownerHex = nostrService.activeHexPubkey
        if (ownerHex.isBlank()) return

        val relays = liveExternalRelaySet(ownerHex)
        if (relays.isEmpty()) return

        // Bound the initial backlog to a week; live events stream after EOSE.
        // Dedup (seenGiftWrapIds / injectedDmIds) absorbs overlap on reconnect.
        val since = System.currentTimeMillis() / 1000 - (7 * 24 * 60 * 60)

        Log.d(TAG, "Opening live DM subscriptions on ${relays.size} external relays")

        for (relayUrl in relays) {
            val client = WebSocketClient(url = relayUrl, scope = scope)
            liveExternalClients.add(client)
            val subId = "dm-live-${UUID.randomUUID().toString().take(8)}"

            // (Re)subscribe on every (re)connect so the filters survive drops.
            scope.launch {
                client.connectionState.collect { state ->
                    if (switchGeneration != generation) return@collect
                    if (state == WebSocketClient.ConnectionState.CONNECTED) {
                        client.send("[\"REQ\",\"$subId-17\",{\"kinds\":[1059],\"#p\":[\"$ownerHex\"],\"since\":$since}]")
                        client.send("[\"REQ\",\"$subId-04in\",{\"kinds\":[4],\"#p\":[\"$ownerHex\"],\"since\":$since}]")
                        client.send("[\"REQ\",\"$subId-04out\",{\"kinds\":[4],\"authors\":[\"$ownerHex\"],\"since\":$since}]")
                    }
                }
            }

            scope.launch {
                client.messages.collect { msg ->
                    if (switchGeneration != generation) return@collect
                    launch(Dispatchers.Default) {
                        handleExternalDmMessage(msg, generation)
                    }
                }
            }

            client.connect()
        }
    }

    /**
     * Periodic catch-up safety net. Runs on the scope's default dispatcher
     * (Main.immediate) so all access to liveExternalClients stays single-threaded;
     * fetchFromExternalRelays() offloads its own heavy work to Dispatchers.IO.
     */
    private fun startPeriodicSync() {
        periodicSyncJob?.cancel()
        periodicSyncJob = scope.launch {
            while (isActive) {
                delay(PERIODIC_SYNC_INTERVAL_MS)
                syncOnForeground()
            }
        }
    }

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

    // ══════════════════════════════════════════════════════════════════
    // Unread management
    // ══════════════════════════════════════════════════════════════════

    fun markRead(pubkey: String) {
        val current = _conversations.value.toMutableList()
        val idx = current.indexOfFirst { it.id == pubkey }
        if (idx >= 0) {
            current[idx] = current[idx].copy(unreadCount = 0)
            _conversations.value = current
            saveCachedConversations()
        }
    }

    fun markAllAsRead() {
        _conversations.value = _conversations.value.map { it.copy(unreadCount = 0) }
        saveCachedConversations()
    }

    // ══════════════════════════════════════════════════════════════════
    // NIP-42 AUTH
    // ══════════════════════════════════════════════════════════════════

    private fun handleAuthChallenge(parsed: JsonArray, client: WebSocketClient?) {
        if (parsed.size < 2) return
        val challenge = parsed[1].jsonPrimitive.contentOrNull ?: return
        val config = configStore.config.value
        // The NIP-42 relay tag must match the chat relay's ServiceURL. The Go relay
        // now builds that from the same scheme this device actually serves locally
        // over (ws://, since Android never enables local TLS — see
        // haven-go/init.go's relayServiceURL), so config.nostrURL's own scheme is
        // already correct here — no need to force wss:// against the client's real
        // connection scheme like this used to.
        val relayUrl = config.localRelayURL("chat") ?: return

        scope.launch(Dispatchers.IO) {
            val tags = listOf(
                listOf("relay", relayUrl),
                listOf("challenge", challenge),
            )
            // Use signEventAsync, NOT the sync signEvent: the sync variant resolves
            // a LOCAL secret key (null under Amber/NIP-46), so /chat AUTH silently
            // failed and no kind-1059 subscription was ever sent — locking all
            // NIP-17 (gift-wrapped) DMs out of the local relay. signEventAsync
            // routes kind-22242 through Amber/NIP-46.
            val authEvent = try {
                nostrService.signEventAsync(
                    kind = 22242,
                    content = "",
                    tags = tags,
                    forceOwner = true,
                )
            } catch (e: Exception) {
                Log.w(TAG, "DBG: /chat AUTH sign failed: ${e.message}")
                null
            } ?: return@launch

            val eventJson = serializeEvent(authEvent)
            Log.w(TAG, "DBG: /chat AUTH event=$eventJson")
            client?.send("[\"AUTH\",$eventJson]")
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Persistence
    // ══════════════════════════════════════════════════════════════════

    private fun loadCachedConversations() {
        scope.launch(Dispatchers.IO) {
            try {
                val key = currentCacheKey()
                val dir = configStore.config.value.appSupportDir ?: run { Log.w(TAG, "DBG: loadCache appSupportDir NULL"); return@launch }
                val file = File(dir, "dm_cache_$key.json")
                if (!file.exists()) { Log.w(TAG, "DBG: loadCache no file key=$key"); return@launch }

                val content = file.readText()
                val rawConvos = json.decodeFromString<List<DMConversation>>(content)

                // One-time repair: earlier builds decrypted inbound NIP-17 gift
                // wraps with a SINGLE nip44 decrypt and stored the still-encrypted
                // seal content (NIP-44 v2 ciphertext) as the message body. Drop
                // those corrupted entries and DO NOT seed their ids, so the live/
                // catch-up subscriptions re-deliver them and the two-layer unwrap
                // decrypts them correctly. NIP-04 messages were never affected.
                var repaired = 0
                val convos = rawConvos.mapNotNull { conv ->
                    val good = conv.messages.filterNot { msg ->
                        (!msg.isNIP04 && looksLikeNip44Ciphertext(msg.content)).also { if (it) repaired++ }
                    }
                    if (good.isEmpty()) null else conv.copy(messages = good)
                }
                Log.w(TAG, "DBG: loadCache key=$key convos=${convos.size} msgs=${convos.sumOf { it.messages.size }} repairedDropped=$repaired")

                // Seed dedup set with the messages we KEPT (the dropped ones must be
                // allowed to re-decrypt).
                for (conv in convos) {
                    for (msg in conv.messages) {
                        seenGiftWrapIds.add(msg.id)
                    }
                }

                withContext(Dispatchers.Main.immediate) {
                    _conversations.value = convos
                }

                if (repaired > 0) {
                    // Persist the cleaned cache and pull the dropped wraps back so
                    // they decrypt with the fixed path.
                    writeCacheNow()
                    fetchFromExternalRelays()
                }
            } catch (e: Exception) {
                Log.w(TAG, "DM cache load failed: ${e.message}")
            }
        }
    }

    /**
     * Debounced cache save. addMessageToConversation() fires this on every
     * message add; during a backlog burst that would otherwise serialize the
     * ENTIRE conversation history to disk N times. Coalesce into a single write
     * ~500 ms after the burst settles. Cancelling the prior job is safe — the
     * write always serializes the latest _conversations snapshot.
     */
    private fun saveCachedConversations() {
        saveJob?.cancel()
        saveJob = scope.launch(Dispatchers.IO) {
            delay(CACHE_SAVE_DEBOUNCE_MS)
            writeCacheNow()
        }
    }

    private fun writeCacheNow() {
        try {
            val key = currentCacheKey()
            val dir = configStore.config.value.appSupportDir ?: return
            val dirFile = File(dir)
            if (!dirFile.exists()) dirFile.mkdirs()

            val file = File(dir, "dm_cache_$key.json")
            file.writeText(json.encodeToString(
                kotlinx.serialization.builtins.ListSerializer(DMConversation.serializer()),
                _conversations.value
            ))
        } catch (e: Exception) {
            Log.w(TAG, "DM cache save failed: ${e.message}")
        }
    }

    private fun currentCacheKey(): String {
        val npub = configStore.config.value.activeAccountNpub
            ?: configStore.config.value.ownerNpub ?: "default"
        return npub.take(12)
    }

    // ══════════════════════════════════════════════════════════════════
    // Utilities
    // ══════════════════════════════════════════════════════════════════

    private fun isAmberMode(): Boolean = configStore.config.value.signingMode == "amber"

    /**
     * Heuristic: does [content] look like a NIP-44 v2 payload rather than human
     * text? NIP-44 v2 = base64( 0x02 || nonce(32) || ciphertext || mac(32) ), so a
     * valid decode whose first byte is 0x02 and whose length is at least the
     * minimum (1+32+32+32 = 97 bytes) is almost certainly leftover ciphertext from
     * the old single-decrypt NIP-17 bug — not a real message. Used only to purge
     * corrupted cached entries on load.
     */
    private fun looksLikeNip44Ciphertext(content: String): Boolean {
        if (content.length < 130 || content.any { it.isWhitespace() }) return false
        return try {
            val raw = android.util.Base64.decode(content, android.util.Base64.DEFAULT)
            raw.size >= 97 && raw[0].toInt() == 0x02
        } catch (_: Exception) {
            false
        }
    }

    private fun resolvePrivateKey(): String? {
        val config = configStore.config.value
        // Amber mode -- no local private key available
        if (config.signingMode == "amber") return null
        return config.ownerHexKey ?: config.ownerNcryptsec?.let { ncryptsec ->
            val password = credentialStore.getKeychainPassword(config.ownerNpub ?: return null)
                ?: return null
            NIP49Service.decrypt(ncryptsec, password)
        }
    }

    private suspend fun fetchRecipientDMRelays(pubkey: String): List<String> {
        // Someone else's advertised 127.0.0.1 is OUR machine, so publishing
        // there drops their DM into our own relay — the write succeeds and the
        // message is lost. Older builds advertised exactly that, so such entries
        // are out there and have to be dropped. Filtering can empty a list;
        // falling through to the next source is what stops that from silently
        // delivering nowhere.
        fun reachable(relays: List<String>?): List<String> =
            relays.orEmpty().filter { !NostrService.isLoopbackRelay(it) }

        reachable(nostrService.dmRelayLists.value[pubkey]).let { if (it.isNotEmpty()) return it }
        reachable(nostrService.relayLists.value[pubkey]).let { if (it.isNotEmpty()) return it.take(3) }

        // Trigger fetch and wait briefly
        nostrService.fetchRelayList(pubkey)
        delay(4_000)

        reachable(nostrService.dmRelayLists.value[pubkey]).let { if (it.isNotEmpty()) return it }
        reachable(nostrService.relayLists.value[pubkey]).let { if (it.isNotEmpty()) return it.take(3) }
        return reachable(configStore.config.value.activeBlastrRelays).take(3)
    }

    private fun fireAndForgetPublish(eventJson: String, relayUrl: String) {
        scope.launch(Dispatchers.IO) {
            try {
                val client = WebSocketClient(url = relayUrl, scope = scope)
                client.connect()
                client.send("[\"EVENT\",$eventJson]")
                delay(FIRE_AND_FORGET_FLUSH_MS)
                client.disconnect()
            } catch (e: Exception) {
                Log.w(TAG, "Fire-and-forget to $relayUrl failed: ${e.message}")
            }
        }
    }

    private fun serializeEvent(event: NostrEvent): String = EventPublisher.serializeSignedEvent(event)
}

// ── Data models ───────────────────────────────────────────────────

@Serializable
data class DMConversation(
    val id: String, // counterparty hex pubkey
    val messages: List<DMMessage>,
    val unreadCount: Int = 0,
) {
    val lastMessage: DMMessage?
        get() = messages.lastOrNull()

    val hasNIP04Messages: Boolean
        get() = messages.any { it.isNIP04 }
}

@Serializable
data class DMMessage(
    val id: String,
    val content: String,
    val timestamp: Long,
    val senderPubkey: String,
    val isFromMe: Boolean,
    val isNIP04: Boolean = false,
)
