package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.remote.WebSocketClient
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import java.io.File
import java.util.UUID
import com.nostrvault.service.DMService.Companion.EXTERNAL_FETCH_LIMIT
import com.nostrvault.service.DMService.Companion.EXTERNAL_FETCH_MAX_RELAYS
import com.nostrvault.service.DMService.Companion.EXTERNAL_FETCH_OVERLAP_MS
import com.nostrvault.service.DMService.Companion.GIFT_WRAP_BACKDATE_SECONDS
import com.nostrvault.service.DMService.Companion.LIVE_EXTERNAL_MAX_RELAYS
import com.nostrvault.service.DMService.Companion.TAG

    // ══════════════════════════════════════════════════════════════════
    // External relay fetching
    // ══════════════════════════════════════════════════════════════════

    fun DMService.fetchFromExternalRelays() {
        backfillSentCopiesIfNeeded()
        // A foreground and a refresh close together asked every relay twice.
        if (!externalFetchRunning.compareAndSet(false, true)) return
        scope.launch(Dispatchers.IO) {
            val ownerHex = nostrService.activeHexPubkey
            val dmRelays = nostrService.dmRelayLists.value[ownerHex] ?: emptyList()
            val inboxRelays = nostrService.relayLists.value[ownerHex] ?: emptyList()
            // Fall back to configured DM relays + Read relays so a fetch still happens
            // when our own kind 10050/10002 isn't cached yet (e.g. a fresh setup
            // or an account that never published a relay list) — otherwise
            // pull-to-refresh queried zero relays and nothing ever loaded.
            val configured = ownDMInboxRelays(ownerHex)
            val read = configStore.config.value.readRelays
            val allRelays = (configured + dmRelays + inboxRelays + read)
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

                        // Cancelled after the pass: a collector never ends by itself, and
                        // left running it held this pass open (externalFetchRunning) for good.
                        val collector = launch {
                            client.messages.collect { msg ->
                                if (switchGeneration != generation) return@collect
                                launch(Dispatchers.Default) {
                                    handleExternalDmMessage(msg, generation)
                                }
                            }
                        }

                        try {
                            client.connect()

                            // NIP-17 (kind 1059). A gift wrap's created_at is
                            // randomized up to 2 days into the past, so the 1-hour
                            // overlap above would miss most new ones.
                            val wrapSince = minOf(since, System.currentTimeMillis() / 1000 - GIFT_WRAP_BACKDATE_SECONDS)
                            // A limit, so a relay holding a flood of wraps can't
                            // send all of them every pass; the live sockets cover the rest.
                            val nip17Filter = """{"kinds":[1059],"#p":["$ownerHex"],"since":$wrapSince,"limit":$EXTERNAL_FETCH_LIMIT}"""
                            client.send("[\"REQ\",\"$subId-17\",$nip17Filter]")

                            // NIP-04 incoming (kind 4)
                            val nip04InFilter = """{"kinds":[4],"#p":["$ownerHex"],"since":$since,"limit":$EXTERNAL_FETCH_LIMIT}"""
                            client.send("[\"REQ\",\"$subId-04in\",$nip04InFilter]")

                            // NIP-04 outgoing (kind 4)
                            val nip04OutFilter = """{"kinds":[4],"authors":["$ownerHex"],"since":$since,"limit":$EXTERNAL_FETCH_LIMIT}"""
                            client.send("[\"REQ\",\"$subId-04out\",$nip04OutFilter]")

                            delay(10_000)
                        } finally {
                            client.disconnect()
                            collector.cancel()
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "External DM fetch from $relayUrl failed: ${e.message}")
                    }
                }
            }

            lastExternalFetchTimestamp = System.currentTimeMillis()
        }.invokeOnCompletion { externalFetchRunning.set(false) }
    }

    /**
     * One-time catch-up, per account, of your own sent copies stranded on
     * your general (kind 10002) relays. Before the DM inbox list (#212) a
     * sent copy could go there, and no device reads DMs from those relays;
     * the regular fetch only reaches 7 days back. Asks your newest 10002
     * relays (fetched fresh — the cache can be long out of date), the cached
     * ones and your DM inbox list for every gift wrap addressed to you, with
     * no time window. Marked done (a file next to the DM cache) only after a
     * fresh 10002 lookup answered, so a launch without network retries.
     * Same as the iOS catch-up in #214.
     */
    private fun DMService.backfillSentCopiesIfNeeded() {
        val ownerHex = nostrService.activeHexPubkey
        val dir = configStore.config.value.appSupportDir ?: return
        if (ownerHex.isBlank() || backfillRunning) return
        val marker = File(dir, "dm_backfill_v1_${ownerHex.take(16)}")
        if (marker.exists()) return
        backfillRunning = true
        val generation = switchGeneration
        scope.launch(Dispatchers.IO) {
            try {
                val fresh = nostrService.fetchNewestReplaceable(10002, ownerHex, ownDMInboxRelays(ownerHex))
                if (switchGeneration != generation) return@launch
                // Every "r" entry, read or write: old builds sent the copy to the read set.
                val freshRelays = fresh?.tags?.filter { it.size >= 2 && it[0] == "r" }?.map { it[1] }.orEmpty()
                val relays = (freshRelays + nostrService.relayLists.value[ownerHex].orEmpty() + ownDMInboxRelays(ownerHex))
                    .map { it.trim().trimEnd('/') }
                    .filter { it.isNotEmpty() && !NostrService.isLoopbackRelay(it) }
                    .distinctBy { it.lowercase() }
                Log.i(TAG, "DM sent-copy catch-up from ${relays.size} relays (fresh 10002: ${fresh != null})")
                coroutineScope {
                    relays.map { url ->
                        launch {
                            val client = WebSocketClient(url = url, scope = this, autoReconnect = false)
                            try {
                                withTimeoutOrNull(12_000) {
                                    val subId = "bf-${UUID.randomUUID().toString().take(6)}"
                                    val done = CompletableDeferred<Unit>()
                                    val collector = launch {
                                        client.messages.collect { msg ->
                                            if (switchGeneration != generation) return@collect
                                            if (msg.startsWith("[\"EOSE\"") || msg.startsWith("[\"CLOSED\"")) {
                                                done.complete(Unit)
                                            } else {
                                                handleExternalDmMessage(msg, generation)
                                            }
                                        }
                                    }
                                    launch {
                                        client.connectionState.first { it == WebSocketClient.ConnectionState.CONNECTED }
                                        client.send("""["REQ","$subId",{"kinds":[1059],"#p":["$ownerHex"],"limit":1000}]""")
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
                if (switchGeneration == generation && fresh != null) marker.writeText("done")
            } catch (e: Exception) {
                Log.w(TAG, "DM sent-copy catch-up failed: ${e.message}")
            } finally {
                backfillRunning = false
            }
        }
    }

    private suspend fun DMService.handleExternalDmMessage(message: String, generation: Int) {
        try {
            val parsed = json.parseToJsonElement(message).jsonArray
            if (parsed.size < 3 || parsed[0].jsonPrimitive.contentOrNull != "EVENT") return

            val eventObj = parsed[2].jsonObject
            val kind = eventObj["kind"]?.jsonPrimitive?.intOrNull ?: return

            when (kind) {
                1059 -> handleIncomingGiftWrap(eventObj, generation, fromExternal = true)
                4 -> handleIncomingNIP04(eventObj, generation, fromExternal = true)
            }
        } catch (_: Exception) {}
    }

    // ══════════════════════════════════════════════════════════════════
    // Live external DM subscription (real-time inbound from public relays)
    // ══════════════════════════════════════════════════════════════════

    /**
     * The PUBLIC relays to keep persistent DM subscriptions on: the relays we
     * advertise in our kind 10050 (where senders deliver to us), plus our cached
     * NIP-65 inbox relays and Read relays as fallbacks. Loopback excluded.
     */
    private fun DMService.liveExternalRelaySet(ownerHex: String): List<String> {
        val advertised = nostrService.dmRelayLists.value[ownerHex] ?: emptyList()
        val inbox = nostrService.relayLists.value[ownerHex] ?: emptyList()
        val configured = ownDMInboxRelays(ownerHex)
        val read = configStore.config.value.readRelays
        return (configured + advertised + inbox + read)
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
    internal fun DMService.connectToExternalDMRelays(generation: Int) {
        // Tear down any previous live subscriptions first.
        liveExternalClients.forEach { it.disconnect() }
        liveExternalClients.clear()

        val ownerHex = nostrService.activeHexPubkey
        if (ownerHex.isBlank()) return

        val relays = liveExternalRelaySet(ownerHex)
        if (relays.isEmpty()) return

        // Bound the initial backlog to a week; live events stream after EOSE.
        // Dedup (seenGiftWrapIds for decrypts, injectedDmIds for relay writes)
        // absorbs overlap on reconnect.
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
