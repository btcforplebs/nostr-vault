package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.CredentialStore
import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.relay.HavenBridge
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
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
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val json = Json { ignoreUnknownKeys = true }

    // ── Observable state ──────────────────────────────────────────────

    private val _conversations = MutableStateFlow<List<DMConversation>>(emptyList())
    val conversations: StateFlow<List<DMConversation>> = _conversations.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

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

    private val seenGiftWrapIds = ConcurrentHashMap.newKeySet<String>()
    private val injectedDmIds = ConcurrentHashMap.newKeySet<String>()
    private var switchGeneration = 0
    private var lastExternalFetchTimestamp = 0L
    private var hasStarted = false

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
        val chatUrl = config.nostrURL?.let { "$it/chat" } ?: return

        inboxClient?.disconnect()
        val client = WebSocketClient(url = chatUrl, scope = scope, trustLocalhost = true)
        inboxClient = client

        scope.launch {
            client.connectionState.collect { state ->
                if (state == WebSocketClient.ConnectionState.CONNECTED) {
                    // NIP-42 AUTH will be needed — handled via AUTH message
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
                    if (success) {
                        val ownerHex = nostrService.activeHexPubkey
                        val filter = """{"kinds":[1059],"#p":["$ownerHex"]}"""
                        inboxClient?.send("[\"REQ\",\"dm-nip17\",$filter]")
                    }
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
                    // Stored gift wraps finished streaming; live events follow.
                    _isLoading.value = false
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Chat relay message parse error: ${e.message}")
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
        if (!seenGiftWrapIds.add(eventId)) { Log.w(TAG, "DBG: giftwrap ${eventId.take(8)} skipped (already seen)"); return }
        if (switchGeneration != generation) return

        withContext(Dispatchers.IO) {
            try {
                val giftWrapContent = eventObj["content"]?.jsonPrimitive?.contentOrNull ?: return@withContext
                val giftWrapPubkey = eventObj["pubkey"]?.jsonPrimitive?.contentOrNull ?: return@withContext
                Log.w(TAG, "DBG: giftwrap ${eventId.take(8)} decrypting (amber=${isAmberMode()})")

                val rumorJson = if (isAmberMode()) {
                    // Amber handles NIP-44 decryption of the gift wrap
                    amberSignerService.nip44Decrypt(giftWrapContent, giftWrapPubkey)
                } else {
                    val recipientPrivkey = resolvePrivateKey() ?: return@withContext
                    NIP17Service.unwrapGiftWrappedDM(giftWrapContent, giftWrapPubkey, recipientPrivkey)
                } ?: run { Log.w(TAG, "DBG: giftwrap ${eventId.take(8)} decrypt returned NULL"); return@withContext }

                // Parse the rumor JSON to extract sender, content, timestamp, tags
                val rumorObj = json.parseToJsonElement(rumorJson).jsonObject
                val senderPubkey = rumorObj["pubkey"]?.jsonPrimitive?.contentOrNull ?: return@withContext
                val content = rumorObj["content"]?.jsonPrimitive?.contentOrNull ?: return@withContext
                val timestamp = rumorObj["created_at"]?.jsonPrimitive?.longOrNull ?: return@withContext
                val rumorTags = rumorObj["tags"]?.jsonArray?.map { t ->
                    t.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" }
                } ?: emptyList()
                val isFromMe = senderPubkey == nostrService.activeHexPubkey

                // Determine counterparty from rumor tags
                val counterparty = if (isFromMe) {
                    rumorTags.firstOrNull { it.size >= 2 && it[0] == "p" }?.get(1) ?: return@withContext
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
            } catch (e: Exception) {
                Log.w(TAG, "Gift wrap unwrap failed: ${e.message}")
            }
        }
    }

    private suspend fun handleIncomingNIP04(eventObj: JsonObject, generation: Int) {
        val eventId = eventObj["id"]?.jsonPrimitive?.contentOrNull ?: return
        if (!seenGiftWrapIds.add(eventId)) { Log.w(TAG, "DBG: nip04 ${eventId.take(8)} skipped (already seen)"); return }
        if (switchGeneration != generation) return

        withContext(Dispatchers.IO) {
            try {
                val pubkey = eventObj["pubkey"]?.jsonPrimitive?.contentOrNull ?: return@withContext
                val content = eventObj["content"]?.jsonPrimitive?.contentOrNull ?: return@withContext
                val createdAt = eventObj["created_at"]?.jsonPrimitive?.longOrNull ?: return@withContext
                val tags = eventObj["tags"]?.jsonArray?.map { t ->
                    t.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" }
                } ?: emptyList()

                val ownerHex = nostrService.activeHexPubkey
                val isFromMe = pubkey == ownerHex
                val counterparty = if (isFromMe) {
                    tags.firstOrNull { it.size >= 2 && it[0] == "p" }?.get(1) ?: return@withContext
                } else {
                    pubkey
                }
                Log.w(TAG, "DBG: nip04 ${eventId.take(8)} fromMe=$isFromMe cp=${counterparty.take(12)} decrypting (amber=${isAmberMode()})")

                // Decrypt (Amber or local key)
                val plaintext = if (isAmberMode()) {
                    amberSignerService.nip04Decrypt(content, counterparty)
                } else {
                    val privkey = resolvePrivateKey() ?: return@withContext
                    NIP04Service.decrypt(content, counterparty, privkey)
                } ?: run { Log.w(TAG, "DBG: nip04 ${eventId.take(8)} decrypt returned NULL"); return@withContext }
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
            } catch (e: Exception) {
                Log.w(TAG, "NIP-04 decrypt failed: ${e.message}")
            }
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

                // Publish to local /chat relay
                val config = configStore.config.value
                val chatUrl = config.nostrURL?.let { "$it/chat" }
                chatUrl?.let {
                    inboxClient?.send("[\"EVENT\",$recipientEvent]")
                    inboxClient?.send("[\"EVENT\",$selfEvent]")
                }

                // Fetch recipient's DM relays and publish
                val recipientRelays = fetchRecipientDMRelays(recipientHexPubkey)
                for (relayUrl in recipientRelays) {
                    fireAndForgetPublish(recipientEvent, relayUrl)
                }

                // Publish self copy to own DM relays
                val ownRelays = nostrService.dmRelayLists.value[ownHexPubkey] ?: emptyList()
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
        // The NIP-42 relay tag must match the chat relay's ServiceURL, which the
        // Go relay sets to "https://" + RELAY_URL + "/chat" → khatru NormalizeURL
        // turns https→wss. We connect over ws:// (local, no TLS), but the AUTH
        // tag must use the wss scheme + bare host or the relay rejects it.
        val host = (config.nostrURL ?: return).substringAfter("://").trimEnd('/')
        val relayUrl = "wss://$host/chat"

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
                val convos = json.decodeFromString<List<DMConversation>>(content)
                Log.w(TAG, "DBG: loadCache key=$key convos=${convos.size} msgs=${convos.sumOf { it.messages.size }}")

                // Seed dedup set
                for (conv in convos) {
                    for (msg in conv.messages) {
                        seenGiftWrapIds.add(msg.id)
                    }
                }

                withContext(Dispatchers.Main.immediate) {
                    _conversations.value = convos
                }
            } catch (e: Exception) {
                Log.w(TAG, "DM cache load failed: ${e.message}")
            }
        }
    }

    private fun saveCachedConversations() {
        scope.launch(Dispatchers.IO) {
            try {
                val key = currentCacheKey()
                val dir = configStore.config.value.appSupportDir ?: return@launch
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
        // Check cached DM relays first
        val dmRelays = nostrService.dmRelayLists.value[pubkey]
        if (!dmRelays.isNullOrEmpty()) return dmRelays

        // Check read relays
        val readRelays = nostrService.relayLists.value[pubkey]
        if (!readRelays.isNullOrEmpty()) return readRelays.take(3)

        // Trigger fetch and wait briefly
        nostrService.fetchRelayList(pubkey)
        delay(4_000)

        return nostrService.dmRelayLists.value[pubkey]
            ?: nostrService.relayLists.value[pubkey]?.take(3)
            ?: configStore.config.value.activeBlastrRelays.take(3)
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
