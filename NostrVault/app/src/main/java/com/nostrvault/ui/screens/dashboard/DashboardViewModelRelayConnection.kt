package com.nostrvault.ui.screens.dashboard

import android.util.Log
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.model.*
import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.service.NostrEvent
import com.nostrvault.service.NostrService
import com.nostrvault.service.ZapValidationService
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*
import com.nostrvault.ui.screens.dashboard.DashboardViewModel.Companion.TAG
import com.nostrvault.ui.screens.dashboard.DashboardViewModel.Companion.MAX_ALL_EVENTS
import com.nostrvault.ui.screens.dashboard.DashboardViewModel.Companion.DOT_BASELINE_DELAY_MS
import com.nostrvault.ui.screens.dashboard.DashboardViewModel.Companion.ALL_EVENTS_TRIM_SLACK
import com.nostrvault.ui.screens.dashboard.DashboardViewModel.Companion.MAX_SEEN_IDS

    /**
     * Thin wrapper for pull-to-refresh. Full reload clears state.
     */
    fun DashboardViewModel.loadLocalRelayNotes() {
        // Pull-to-refresh: ask the embedded relay to fetch newly tagged events
        // (replies, reactions, zaps, reposts, mentions, DMs) and the owner's own
        // notes from external relays into the local DBs. Injected events then
        // stream in over the local subscription opened below. Non-blocking.
        runCatching { com.nostrvault.relay.HavenBridge.requestRelaySync() }
            .onFailure { Log.w(TAG, "requestRelaySync failed: ${it.message}") }

        // Keep existing data and only fetch new events (don't clear or full reload)
        _isRefreshing.value = true
        // Ask again for liked and zapped posts that are still missing.
        forgetGivenLookups()
        when (_viewMode.value) {
            VaultViewMode.LIKES -> fetchMissingLikedNotes()
            VaultViewMode.ZAPS -> {
                fetchMoreZapReceipts()
                fetchMissingZappedNotes()
            }
            else -> {}
        }

        // Reuse live sockets: re-send the since-bounded subscriptions instead of
        // tearing every connection down and replaying the whole window. Only
        // rebuild connections when they're actually gone/dead.
        if (!resendVaultSubscriptions()) {
            connectToLocalRelay()
        }
    }

    /**
     * Re-sends the vault subscriptions on live connections so events the relay
     * imported since the last REQ stream in (the importer writes straight to
     * its DBs and never notifies open subscriptions). Returns false when the
     * local connections aren't up — caller decides whether to reconnect.
     */
    internal fun DashboardViewModel.resendVaultSubscriptions(): Boolean {
        val outboxUp = outboxClient?.connectionState?.value == WebSocketClient.ConnectionState.CONNECTED
        val inboxUp = inboxClient?.connectionState?.value == WebSocketClient.ConnectionState.CONNECTED
        if (!outboxUp || !inboxUp) return false

        val authors = buildAuthorSet()
        val ownerHex = nostrService.activeHexPubkey
        val config = configStore.config.value
        val localUrl = config.nostrURL ?: return false
        val inboxUrl = config.localInboxURL ?: return false
        val macWss = config.macRelayWssURL

        outboxClient?.let { sendVaultSubscription(it, "vault-outbox", authors, ownerHex, localUrl) }
        inboxClient?.let { sendVaultSubscription(it, "vault-inbox", authors, ownerHex, inboxUrl) }
        // Re-pull the Mac relay (source of truth) too so we converge on its data
        macOutboxClient?.takeIf { it.connectionState.value == WebSocketClient.ConnectionState.CONNECTED }
            ?.let { sendVaultSubscription(it, "vault-mac-outbox", authors, ownerHex, macWss) }
        macInboxClient?.takeIf { it.connectionState.value == WebSocketClient.ConnectionState.CONNECTED }
            ?.let { sendVaultSubscription(it, "vault-mac-inbox", authors, ownerHex, "$macWss/inbox") }
        return true
    }

    /**
     * Creates persistent WebSocket connections to the local relay (outbox + inbox).
     * Message collectors feed into shared allEvents; subscriptions are sent
     * automatically when the connection reaches CONNECTED state.
     */
    internal fun DashboardViewModel.connectToLocalRelay() {
        val config = configStore.config.value
        if (config.nostrURL == null) {
            _connectionStatus.value = "No vault"
            _connectionColor.value = "red"
            return
        }
        val localUrl = config.nostrURL ?: return
        val inboxUrl = config.localInboxURL ?: return
        val ownerHex = nostrService.activeHexPubkey
        val authors = buildAuthorSet()

        Log.d(TAG, "connectToLocalRelay: outbox=$localUrl, inbox=$inboxUrl, authors=${authors.size}, fullReload=$isFullReload")

        disconnectFromLocalRelay()

        _connectionStatus.value = "Connecting..."
        _connectionColor.value = "yellow"

        // --- Outbox connection ---
        val outbox = WebSocketClient(url = localUrl, scope = viewModelScope, trustLocalhost = true)
        outboxClient = outbox

        val outboxMsgJob = viewModelScope.launch(Dispatchers.IO) {
            outbox.messages.collect { msg -> processRelayMessage(msg, localUrl) }
        }
        val outboxStateJob = viewModelScope.launch {
            outbox.connectionState.collect { state ->
                when (state) {
                    WebSocketClient.ConnectionState.CONNECTED -> {
                        sendVaultSubscription(outbox, "vault-outbox", authors, ownerHex, localUrl)
                        updateConnectionStatus()
                    }
                    WebSocketClient.ConnectionState.DISCONNECTED -> updateConnectionStatus()
                    else -> {}
                }
            }
        }

        // --- Inbox connection ---
        val inbox = WebSocketClient(url = inboxUrl, scope = viewModelScope, trustLocalhost = true)
        inboxClient = inbox

        val inboxMsgJob = viewModelScope.launch(Dispatchers.IO) {
            inbox.messages.collect { msg -> processRelayMessage(msg, inboxUrl) }
        }
        val inboxStateJob = viewModelScope.launch {
            inbox.connectionState.collect { state ->
                when (state) {
                    WebSocketClient.ConnectionState.CONNECTED -> {
                        sendVaultSubscription(inbox, "vault-inbox", authors, ownerHex, inboxUrl)
                        updateConnectionStatus()
                    }
                    WebSocketClient.ConnectionState.DISCONNECTED -> updateConnectionStatus()
                    else -> {}
                }
            }
        }

        val jobs = mutableListOf(outboxMsgJob, outboxStateJob, inboxMsgJob, inboxStateJob)

        // --- Mac relay connections (source-of-truth, shared with iOS/macOS) ---
        // Real cert on a public domain → normal system trust (trustLocalhost = false).
        // The inbox relay requires no AUTH to query, so a plain REQ returns the
        // tagged replies/reactions/zaps the local embedded relay hasn't imported yet.
        val macWss = config.macRelayWssURL
        if (macWss.isNotEmpty()) {
            val macInboxUrl = "$macWss/inbox"
            Log.d(TAG, "connectToLocalRelay: mac outbox=$macWss, mac inbox=$macInboxUrl")

            val macOutbox = WebSocketClient(url = macWss, scope = viewModelScope, trustLocalhost = false)
            macOutboxClient = macOutbox
            jobs += viewModelScope.launch(Dispatchers.IO) {
                macOutbox.messages.collect { msg -> processRelayMessage(msg, macWss) }
            }
            jobs += viewModelScope.launch {
                macOutbox.connectionState.collect { state ->
                    when (state) {
                        WebSocketClient.ConnectionState.CONNECTED ->
                            sendVaultSubscription(macOutbox, "vault-mac-outbox", authors, ownerHex, macWss)
                        else -> {}
                    }
                }
            }

            val macInbox = WebSocketClient(url = macInboxUrl, scope = viewModelScope, trustLocalhost = false)
            macInboxClient = macInbox
            jobs += viewModelScope.launch(Dispatchers.IO) {
                macInbox.messages.collect { msg -> processRelayMessage(msg, macInboxUrl) }
            }
            jobs += viewModelScope.launch {
                macInbox.connectionState.collect { state ->
                    when (state) {
                        WebSocketClient.ConnectionState.CONNECTED ->
                            sendVaultSubscription(macInbox, "vault-mac-inbox", authors, ownerHex, macInboxUrl)
                        else -> {}
                    }
                }
            }
        }

        clientJobs = jobs
        outbox.connect()
        inbox.connect()
        macOutboxClient?.connect()
        macInboxClient?.connect()
    }

    /**
     * Sends a Nostr REQ subscription on an existing connection.
     */
    private fun DashboardViewModel.sendVaultSubscription(
        client: WebSocketClient,
        subId: String,
        authors: Set<String>,
        ownerHex: String,
        relayUrl: String,
    ) {
        // Track this relay as active and reset EOSE tracking
        activeRelayUrls.add(relayUrl)
        relayEoseReceived[relayUrl] = false

        val authorsJson = authors.joinToString(",") { "\"$it\"" }
        // Always cap the stored-event replay. Without a limit the relay dumps the
        // entire vault history on every connect. When we already hold events
        // (resume re-subscribe), only ask for the gap since the newest one.
        val newest = newestEventCreatedAt
        val sinceClause = if (!isFullReload && newest > 0) ",\"since\":${newest - 60}" else ""

        val authorFilter = """{"kinds":[1,6,7,30023,1111,9802,9735,1068],"authors":[$authorsJson]$sinceClause,"limit":500}"""

        val filters = if (ownerHex.isNotEmpty()) {
            // IMPORTANT: Mentions filter should NOT use sinceClause - we want ALL notes
            // where the user is tagged, not just recent ones. This fixes the bug where
            // older tagged notes never appear in the TAGGED filter.
            val mentionsFilter = """{"kinds":[1,6,7,30023,1111,9802,9735,1068],"#p":["$ownerHex"],"limit":500}"""
            "$authorFilter,$mentionsFilter"
        } else {
            authorFilter
        }

        Log.d(TAG, "sendVaultSubscription: subId=$subId, fullReload=$isFullReload")
        client.send("""["REQ","$subId",$filters]""")
    }

    /**
     * Processes a single relay message from either the outbox or inbox connection.
     * Deduplicates via seenIds, routes metadata to NostrService, accumulates
     * content events into allEvents, and schedules a display update.
     */
    private suspend fun DashboardViewModel.processRelayMessage(msg: String, relayUrl: String) {
        try {
            val parsed = json.parseToJsonElement(msg).jsonArray
            val type = parsed[0].jsonPrimitive.contentOrNull ?: return

            when (type) {
                "EVENT" -> {
                    if (parsed.size < 3) return
                    val eventObj = parsed[2].jsonObject
                    val id = eventObj["id"]?.jsonPrimitive?.contentOrNull ?: return
                    if (!seenIds.add(id)) return

                    val pubkey = eventObj["pubkey"]?.jsonPrimitive?.contentOrNull ?: return
                    val kind = eventObj["kind"]?.jsonPrimitive?.intOrNull ?: return
                    val content = eventObj["content"]?.jsonPrimitive?.contentOrNull ?: ""
                    val createdAt = eventObj["created_at"]?.jsonPrimitive?.longOrNull ?: return
                    val sig = eventObj["sig"]?.jsonPrimitive?.contentOrNull ?: ""
                    val tags = eventObj["tags"]?.jsonArray?.map { tagArr ->
                        tagArr.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" }
                    } ?: emptyList()

                    // Metadata events go to NostrService
                    if (kind in listOf(0, 10002, 10050, 10063, 10000)) {
                        nostrService.processRelayMessage(msg, relayUrl)
                        return
                    }

                    // NIP-57: a zap receipt is spoofable by anyone who can reach a relay
                    // we query — only trust it if it came from the pubkey the recipient's
                    // own LNURL endpoint designates as authorized to publish on their behalf.
                    if (kind == 9735) {
                        val recipientPubkey = tags.firstOrNull { it.size >= 2 && it[0] == "p" }?.get(1)
                        if (recipientPubkey == null || !ZapValidationService.isValidReceipt(
                                receiptPubkey = pubkey,
                                recipientPubkey = recipientPubkey,
                                profiles = nostrService.profiles.value,
                            )
                        ) {
                            return
                        }
                    }

                    val nostrEvent = NostrEvent(
                        id = id,
                        pubkey = pubkey,
                        createdAt = createdAt,
                        kind = kind,
                        tags = tags,
                        content = content,
                        sig = sig,
                    )

                    allEventsMutex.withLock {
                        allEvents.add(nostrEvent)
                        trimAllEventsLocked()
                    }
                    // Future-dated junk must not poison the resume catch-up window
                    val nowSecs = System.currentTimeMillis() / 1000
                    if (createdAt > newestEventCreatedAt && createdAt <= nowSecs + 60) {
                        newestEventCreatedAt = createdAt
                    }

                    if (seenIds.size > MAX_SEEN_IDS) {
                        val retained = allEventsMutex.withLock { allEvents.mapTo(HashSet()) { it.id } }
                        seenIds.retainAll(retained)
                        seenIds.add(id)
                    }

                    nostrService.fetchMissingProfiles(listOf(pubkey))
                    scheduleUpdateDisplayData()
                }
                "EOSE" -> {
                    if (parsed.size >= 2) {
                        val subId = parsed[1].jsonPrimitive.contentOrNull
                        val eventCount = allEventsMutex.withLock { allEvents.size }
                        Log.d(TAG, "EOSE received from $relayUrl, subId=$subId, total events loaded: $eventCount")

                        // Track that this relay has sent EOSE
                        relayEoseReceived[relayUrl] = true

                        // If all connected relays have sent EOSE, finalize loading
                        if (allRelaysFinished()) {
                            handleEOSE()
                        }
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Parse error: ${e.message}")
        }
    }

    /** Caller must hold [allEventsMutex]. Trims oldest events past the cap. */
    internal fun DashboardViewModel.trimAllEventsLocked() {
        if (allEvents.size > MAX_ALL_EVENTS + ALL_EVENTS_TRIM_SLACK) {
            // Articles and highlights are kept: their "Load older" pages are
            // the oldest events here by design, and trimming them would throw
            // a page away as it lands while its cursor moved on past it.
            val pagedApart = setOf(VaultNoteScope.ARTICLE_KIND, VaultNoteScope.HIGHLIGHT_KIND)
            val (kept, rest) = allEvents.partition { it.kind in pagedApart }
            val newest = rest.sortedByDescending { it.createdAt }
                .take((MAX_ALL_EVENTS - kept.size).coerceAtLeast(0))
            allEvents.clear()
            allEvents.addAll(newest)
            allEvents.addAll(kept)
        }
    }

    /**
     * Checks if all connected relays have sent EOSE.
     */
    internal fun DashboardViewModel.allRelaysFinished(): Boolean {
        // If no relays are active, consider it finished
        if (activeRelayUrls.isEmpty()) return true

        // Check if all active relays have sent EOSE
        return activeRelayUrls.all { url ->
            relayEoseReceived[url] == true
        }
    }

    /**
     * Called when all relays have sent EOSE (end of stored events).
     * Updates connection state and stops the refresh spinner.
     */
    internal fun DashboardViewModel.handleEOSE() {
        viewModelScope.launch(Dispatchers.Main.immediate) {
            _isRefreshing.value = false
            _notesHasLoadedOnce.value = true
            isFullReload = false
            updateConnectionStatus()
            loadFirstPageInScope()
            // All stored events are in — bypass the debounce
            updateJob?.cancel()
            updateGeneration++
            updateDisplayData(updateGeneration)
            // As iOS: the dots count from a few seconds after the first load,
            // once the stored burst and the live catch-up are in.
            if (dotSeenAt.isEmpty() && dotBaselineJob == null) {
                dotBaselineJob = viewModelScope.launch {
                    delay(DOT_BASELINE_DELAY_MS)
                    val newest = dotNewest()
                    VaultDots.eventLists.forEach { dotSeenAt[it] = newest.getValue(it) }
                    _newActivity.value = emptySet()
                }
            }
        }
    }

    internal fun DashboardViewModel.disconnectFromLocalRelay() {
        clientJobs.forEach { it.cancel() }
        clientJobs.clear()
        outboxClient?.disconnect()
        inboxClient?.disconnect()
        macOutboxClient?.disconnect()
        macInboxClient?.disconnect()
        outboxClient = null
        inboxClient = null
        macOutboxClient = null
        macInboxClient = null

        // Clear EOSE tracking state
        activeRelayUrls.clear()
        relayEoseReceived.clear()
    }

    // ── Snapshot persistence ─────────────────────────────────────

    private fun DashboardViewModel.updateConnectionStatus() {
        val outboxConnected = outboxClient?.connectionState?.value == WebSocketClient.ConnectionState.CONNECTED
        val inboxConnected = inboxClient?.connectionState?.value == WebSocketClient.ConnectionState.CONNECTED
        when {
            outboxConnected && inboxConnected -> {
                val count = _displayNotes.value.size
                _connectionStatus.value = if (count > 0) "Local ($count)" else "Live"
                _connectionColor.value = "green"
            }
            outboxConnected || inboxConnected -> {
                _connectionStatus.value = "Partial"
                _connectionColor.value = "yellow"
            }
            outboxClient != null -> {
                // Clients exist but not connected yet (connecting/reconnecting)
                _connectionStatus.value = "Connecting..."
                _connectionColor.value = "yellow"
            }
            else -> {
                _connectionStatus.value = "Offline"
                _connectionColor.value = "red"
            }
        }
    }
