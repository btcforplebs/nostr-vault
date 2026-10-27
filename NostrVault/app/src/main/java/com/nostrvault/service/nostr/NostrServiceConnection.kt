package com.nostrvault.service

import android.util.Log
import com.nostrvault.BuildConfig
import com.nostrvault.data.remote.WebSocketClient
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*
import kotlin.concurrent.withLock
import com.nostrvault.service.NostrService.Companion.TAG

    fun NostrService.initialize() {
        if (BuildConfig.DEBUG) Log.d(TAG, "initialize: ownerHexPubkey=${ownerHexPubkey.take(16)}... (from ownerNpub=${configStore.config.value.ownerNpub.take(20)}...)")
        loadProfilesFromDisk()
        observeAccountSwitch()
        observeMuteList()
    }

    internal fun NostrService.observeAccountSwitch() {
        scope.launch {
            configStore.accountSwitches.collect { handleAccountSwitch() }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Account switching
    // ══════════════════════════════════════════════════════════════════

    fun NostrService.handleAccountSwitch() {
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

    private fun NostrService.reconnectForActiveAccount() {
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
    fun NostrService.connectToRelay(
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

    fun NostrService.disconnectAll() {
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

    fun NostrService.closeSubscription(relayUrl: String, subscriptionId: String) {
        val normalizedUrl = normalizeRelayUrl(relayUrl)
        clients[normalizedUrl]?.send("[\"CLOSE\",\"$subscriptionId\"]")
        activeSubscriptions.remove(normalizedUrl)
    }

    // ══════════════════════════════════════════════════════════════════
    // Connection status
    // ══════════════════════════════════════════════════════════════════

    fun NostrService.updateConnectionStatus() {
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
