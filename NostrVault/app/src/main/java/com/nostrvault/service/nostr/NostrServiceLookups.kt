package com.nostrvault.service

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import java.util.UUID
import kotlinx.coroutines.sync.withPermit
import kotlin.concurrent.withLock
import com.nostrvault.service.NostrService.Companion.PROFILE_RELAYS
import com.nostrvault.service.NostrService.Companion.RELAY_LIST_CHUNK
import com.nostrvault.service.NostrService.Companion.RELAY_LIST_TIMEOUT_MS
import com.nostrvault.service.NostrService.Companion.TEMP_CLIENT_DISCONNECT_MS
import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.NostrService.ReplaceableLookup
import com.nostrvault.service.NostrService.Companion.isLoopbackRelay

    internal fun NostrService.parseRelayListEvent(pubkey: String, tags: List<List<String>>, createdAt: Long) {
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

    internal fun NostrService.parseDmRelayListEvent(pubkey: String, tags: List<List<String>>) {
        val dmRelays = profileRepository.parseDMRelayListTags(tags)
        if (dmRelays.isNotEmpty()) {
            scope.launch(Dispatchers.Main.immediate) {
                _dmRelayLists.value = _dmRelayLists.value + (pubkey to dmRelays)
            }
        }
    }

    internal fun NostrService.parseServerListEvent(pubkey: String, tags: List<List<String>>, createdAt: Long) {
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

    // A linked Mac missing from the owner's 10063 is listed by Save in
    // Media servers only. Reading a 10063 never publishes one: it used to
    // republish the user's list on its own (Logen 2026-10-31).

    // ══════════════════════════════════════════════════════════════════
    // Relay list fetching
    // ══════════════════════════════════════════════════════════════════

    /**
     * Fetch relay list (kinds 10002, 10050) for a specific pubkey.
     */
    fun NostrService.fetchRelayList(pubkey: String) {
        if (_relayLists.value.containsKey(pubkey) && _dmRelayLists.value.containsKey(pubkey)) {
            return
        }

        val subId = "relays-${UUID.randomUUID().toString().take(8)}"
        val filter = buildMap<String, Any> {
            put("kinds", listOf(10002, 10050))
            put("authors", listOf(pubkey))
            put("limit", 2)
        }

        // The profile relays too: purplepag.es and user.kindpag.es index
        // relay lists, so a stranger's outbox is found when no read relay has it.
        val relays = (configStore.config.value.readRelays.take(3) + PROFILE_RELAYS)
            .distinctBy { com.nostrvault.data.remote.LookupSocketPool.relayKey(it) }
        for (relayUrl in relays) {
            if (!isValidRelayUrl(relayUrl)) continue
            scope.launch(Dispatchers.IO) {
                lookupPool.query(relayUrl, subId, listOf(buildFilterJson(filter)), TEMP_CLIENT_DISCONNECT_MS) { msg ->
                    launch(Dispatchers.Default) { processRelayMessage(msg, relayUrl) }
                }
            }
        }
    }

    internal fun NostrService.fetchServerListImpl(pubkey: String) {
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

    private fun NostrService.queryServerList(pubkey: String, outboxOnly: Boolean = false) {
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

    /** The relays a profile page asks: local, up to 3 feed relays, up to 3 of the profile's outbox. */
    fun NostrService.profileRelayUrls(pubkey: String): List<String> {
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
     * Fetch NIP-65 relay lists (kind 10002) for many pubkeys at once, on the
     * pooled lookup sockets. The metadata pool asks for kind 0 only, so a
     * forced [fetchMissingProfiles] never brings these in. Asks the user's own
     * relay and the profile relays (purplepag.es and user.kindpag.es index
     * relay lists).
     */
    fun NostrService.fetchRelayLists(pubkeys: List<String>) {
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
     * The newest signed kind 10050 for [pubkey] across the blastr relays and
     * [alsoAsk], as (relays, created_at), or null if none answered in time.
     * Asks fresh rather than trusting the cached [dmRelayLists], which would
     * let a device adopt its own stale copy.
     */
    internal suspend fun NostrService.fetchNewestDMRelayList(pubkey: String, alsoAsk: List<String>, timeoutMs: Long = 6_000): Pair<List<String>, Long>? {
        val winner = fetchNewestReplaceable(10050, pubkey, alsoAsk, timeoutMs) ?: return null
        return profileRepository.parseDMRelayListTags(winner.tags) to winner.createdAt
    }

    /**
     * The newest signed replaceable event of [kind] by [pubkey] across the
     * blastr relays and [alsoAsk], or null if none answered in time. Asks
     * fresh: the profile caches can hold a list replaced long ago.
     */
    internal suspend fun NostrService.fetchNewestReplaceableImpl(kind: Int, pubkey: String, alsoAsk: List<String>, timeoutMs: Long = 6_000): NostrEvent? =
        lookupNewestReplaceable(kind, pubkey, alsoAsk, timeoutMs).event

    /** [fetchNewestReplaceable], also saying whether "none" was confirmed. */
    internal suspend fun NostrService.lookupNewestReplaceableImpl(kind: Int, pubkey: String, alsoAsk: List<String>, timeoutMs: Long = 6_000, dTag: String? = null): ReplaceableLookup {
        val targets = (configStore.config.value.activeBlastrRelays + alsoAsk)
            .map { it.trim() }
            .filter { it.isNotEmpty() && !isLoopbackRelay(it) }
            .distinct()
        if (targets.isEmpty()) return ReplaceableLookup(null, 0, 0)
        val best = java.util.concurrent.atomic.AtomicReference<NostrEvent?>(null)
        val answered = java.util.concurrent.atomic.AtomicInteger(0)
        val answeredBy = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
        val ahead = java.util.concurrent.atomic.AtomicBoolean(false)
        val newestBy = java.util.concurrent.ConcurrentHashMap<String, NostrEvent>()
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
                                    when ((arr.getOrNull(0) as? JsonPrimitive)?.contentOrNull) {
                                        "EVENT" -> {
                                            val obj = (arr.getOrNull(2) as? JsonObject) ?: return@collect
                                            val ev = parseSignedEvent(obj.toString()) ?: return@collect
                                            if (ev.kind != kind || ev.pubkey != pubkey || !HavenBridge.verifyEvent(obj.toString())) return@collect
                                            if (dTag != null && ev.tags.none { it.size >= 2 && it[0] == "d" && it[1] == dTag }) return@collect
                                            // Dated too far ahead: never the newest copy (an edit signed now would lose to it).
                                            if (!ListMerge.notAhead(ev.createdAt)) { ahead.set(true); return@collect }
                                            best.updateAndGet { cur -> if (cur == null || ev.createdAt > cur.createdAt) ev else cur }
                                            newestBy.merge(url, ev) { a, b -> if (b.createdAt > a.createdAt) b else a }
                                        }
                                        "EOSE" -> {
                                            val ours = (arr.getOrNull(1) as? JsonPrimitive)?.contentOrNull == subId
                                            if (done.complete(Unit) && ours) {
                                                answered.incrementAndGet()
                                                answeredBy.add(url)
                                            }
                                        }
                                        "CLOSED" -> done.complete(Unit)
                                    }
                                }
                            }
                            launch {
                                client.connectionState.first { it == WebSocketClient.ConnectionState.CONNECTED }
                                val dFilter = dTag?.let { ""","#d":[${JsonPrimitive(it)}]""" } ?: ""
                                client.send("""["REQ","$subId",{"kinds":[$kind],"authors":["$pubkey"]$dFilter,"limit":1}]""")
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
        val newest = best.get()
        val from = newestBy.filterValues { newest != null && it.id == newest.id }.keys
        return ReplaceableLookup(newest, targets.size, answered.get(), answeredBy.toSet(), from.toSet(), ahead.get())
    }

    /**
     * [target]'s follower count from Vertex, the source npub.world uses. Null
     * when Vertex isn't asked or can't answer: Settings > Privacy has it off
     * (the default), no local key (a bunker or Amber would be asked to sign
     * for every profile opened), no credits, or no answer in time.
     * The request is signed by the active account and names [target].
     * Mirrors iOS NostrService.fetchVertexFollowerCount.
     */
    internal suspend fun NostrService.fetchVertexFollowerCountImpl(target: String, timeoutMs: Long = 6_000): Int? {
        val vertex = com.nostrvault.data.model.VertexReputation
        val now = System.currentTimeMillis()
        vertexCache.followers(target, now)?.let { return it }
        val config = configStore.config.value
        if (!config.vertexLookups || !vertexCache.shouldAsk(now) || config.activeSigningMode() != "local") return null
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
                                if ((arr.getOrNull(0) as? JsonPrimitive)?.contentOrNull != "EVENT") return@collect
                                val obj = (arr.getOrNull(2) as? JsonObject) ?: return@collect
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
