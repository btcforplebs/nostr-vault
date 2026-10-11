package com.nostrvault.service

import android.util.Log
import com.nostrvault.BuildConfig
import com.nostrvault.data.remote.WebSocketClient
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import com.nostrvault.service.DMService.Companion.PERIODIC_SYNC_INTERVAL_MS
import com.nostrvault.service.DMService.Companion.TAG

    /** Saves the old account's inbox under its own key, then starts the new one's. */
    internal fun DMService.switchAccount() {
        saveJob?.cancel()
        pendingSaveJob?.cancel()
        val conversations = _conversations.value
        val pending = pendingDecryptQueue.toList()
        val oldKey = loadedCacheKey
        scope.launch(Dispatchers.IO) {
            if (oldKey != null) {
                writeCache(oldKey, conversations)
                // The old account's undecrypted backlog belongs to its own
                // file; startListening is about to clear the queue.
                writePendingQueue(oldKey, pending)
            }
        }

        _conversations.value = emptyList()
        seenGiftWrapIds.clear()
        injectedDmIds.clear()
        openedMessages.clear()
        sentSelfWrapIds.clear()
        visibleConversation = null
        warnedNoDmKey.set(false)
        startListening()
    }

    fun DMService.startListening() {
        hasStarted = true
        switchGeneration++
        val generation = switchGeneration

        // Drop any pending decrypts queued for a previous account/generation.
        pendingDecryptQueue.clear()
        queuedDecryptIds.clear()
        injectionQueue.clear()
        chatAuthEventId = null
        _pendingDecryptCount.value = 0
        _decryptBlocked.value = false
        lastBlockedSize = -1
        chatResubJob?.cancel()

        loadCachedConversations()
        // Pick the signer backlog back up before any socket work, so a
        // restart does not depend on a relay re-serving those wraps.
        restorePendingDecrypts(generation)
        connectToLocalChatRelay(generation)
        connectToLocalNip04Relay(generation)
        // Persistent subscriptions to our public DM relays so inbound replies
        // arrive in real-time (the local sockets only see DMs already in the DB).
        connectToExternalDMRelays(generation)
        startPeriodicSync()
    }

    // ══════════════════════════════════════════════════════════════════
    // Local relay connections
    // ══════════════════════════════════════════════════════════════════

    private fun DMService.connectToLocalChatRelay(generation: Int) {
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

    private fun DMService.connectToLocalNip04Relay(generation: Int) {
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

    private fun DMService.subscribeToNip04(client: WebSocketClient) {
        val ownerHex = nostrService.activeHexPubkey
        val subId = "dm-nip04"
        if (BuildConfig.DEBUG) Log.w(TAG, "DBG: subscribeToNip04 ownerHex=${ownerHex.take(12)} amber=${isAmberMode()}")

        // Incoming NIP-04 DMs
        val inFilter = """{"kinds":[4],"#p":["$ownerHex"]}"""
        client.send("[\"REQ\",\"$subId-in\",$inFilter]")

        // Outgoing NIP-04 DMs (sent by us)
        val outFilter = """{"kinds":[4],"authors":["$ownerHex"]}"""
        client.send("[\"REQ\",\"$subId-out\",$outFilter]")
    }

    /** (Re)send the kind-1059 subscription on the authed /chat socket. */
    internal fun DMService.sendChatNip17Req() {
        val ownerHex = nostrService.activeHexPubkey
        if (ownerHex.isBlank()) return
        inboxClient?.send("[\"REQ\",\"dm-nip17\",{\"kinds\":[1059],\"#p\":[\"$ownerHex\"]}]")
    }

    /**
     * Retry the /chat kind-1059 subscription on a backoff while the relay's Web of
     * Trust is still warming up (it rejects queries with CLOSED until ~60s after
     * launch). Cancelled as soon as an EOSE confirms the sub was accepted.
     */
    internal fun DMService.scheduleChatResubscribe(generation: Int) {
        if (chatResubJob?.isActive == true) return
        chatResubJob = scope.launch {
            var attempt = 0
            while (isActive && switchGeneration == generation && attempt < 12) {
                delay(12_000)
                if (switchGeneration != generation) return@launch
                attempt++
                if (BuildConfig.DEBUG) Log.w(TAG, "DBG: /chat re-subscribe dm-nip17 attempt=$attempt")
                sendChatNip17Req()
            }
        }
    }

    /**
     * Periodic catch-up safety net. Runs on the scope's default dispatcher
     * (Main.immediate) so all access to liveExternalClients stays single-threaded;
     * fetchFromExternalRelays() offloads its own heavy work to Dispatchers.IO.
     */
    private fun DMService.startPeriodicSync() {
        periodicSyncJob?.cancel()
        periodicSyncJob = scope.launch {
            while (isActive) {
                delay(PERIODIC_SYNC_INTERVAL_MS)
                syncOnForeground()
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // NIP-42 AUTH
    // ══════════════════════════════════════════════════════════════════

    internal fun DMService.handleAuthChallenge(parsed: JsonArray, client: WebSocketClient?) {
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
                if (BuildConfig.DEBUG) Log.w(TAG, "DBG: /chat AUTH sign failed: ${e.message}")
                null
            } ?: return@launch

            val eventJson = serializeEvent(authEvent)
            if (BuildConfig.DEBUG) Log.w(TAG, "DBG: /chat AUTH event=$eventJson")
            // Remember it: the relay's OK for THIS id is what releases the
            // kind-1059 subscription (see handleChatRelayMessage).
            chatAuthEventId = authEvent.id
            client?.send("[\"AUTH\",$eventJson]")
        }
    }
