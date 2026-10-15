package com.nostrvault.ui.components

import com.nostrvault.data.model.GlobeArcs
import com.nostrvault.data.model.GlobeStorm
import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.service.FeedService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.util.UUID

/**
 * One of the globe's REQs on one relay, riding the feed's open connection to it
 * (iOS `GlobeRelayLink.swift`): the feed already holds one to each of your read
 * relays, so the globe opens none of its own. Its subscription ids start
 * `arcs-`, which the feed skips, and closing it CLOSEs only those. A reconnect,
 * or the feed swapping in a new connection, sends it again. Only a relay the
 * feed has held no connection to since the globe opened gets one of the globe's
 * own, closed with it.
 *
 * The link's bookkeeping runs on [scope]'s main thread; relay messages are read
 * on [Dispatchers.Default], where [onEvent] is called.
 */
internal class GlobeRelayLink(
    val url: String,
    filters: List<JsonObject>,
    private val feed: FeedService,
    private val scope: CoroutineScope,
    private val onEvent: (JsonObject) -> Unit,
) {
    /** The REQ messages, already split under the relay's size cap. */
    val requests: List<String> =
        GlobeArcs.requests(filters, GlobeStorm.SUBSCRIPTION_PREFIX + UUID.randomUUID().toString().take(8))
    /**
     * This link's own sub ids. Two links can share one socket (the wide REQ and
     * the notes-to-you REQ on a read relay): each reads only its own answers.
     */
    private val ids: Set<String> = requests.mapNotNullTo(HashSet()) { GlobeStorm.subscriptionOf(it) }
    private var client: WebSocketClient? = null
    /** The globe opened [client] itself: it disconnects it when done. */
    private var owned = false
    /** Rode the feed's connection once: while the feed reconnects, wait for it rather than open one of our own. */
    private var everShared = false
    private var jobs: List<Job> = emptyList()
    /** Notices the feed swapping its connection, which it does on a reconnect. */
    private val recheck: Job = scope.launch(Dispatchers.Main.immediate) {
        while (isActive) {
            attach()
            delay(RECHECK_MS)
        }
    }

    /** CLOSEs the globe's subscriptions; the feed's connection stays open. */
    fun close() {
        recheck.cancel()
        detach()
    }

    private fun attach() {
        val shared = feed.feedClients[url]
        client?.let { current ->
            // Still on the feed's current connection, or on our own while the
            // feed has none: nothing to do.
            if (if (owned) shared == null else current === shared) return
            detach()
        }
        val next = when {
            shared != null -> shared.also { owned = false; everShared = true }
            everShared -> return
            else -> WebSocketClient(url = url, scope = scope,
                trustLocalhost = url.contains("localhost") || url.contains("127.0.0.1")).also {
                owned = true
                it.connect()
            }
        }
        client = next
        val prefix = GlobeStorm.SUBSCRIPTION_PREFIX
        jobs = listOf(
            // The feed's own messages go past here too: only the globe's are read.
            // The cheap contains() keeps a full parse off every feed message; an
            // escaped sub id slips past it and just doesn't fly (the feed still skips it).
            // Subscribed before the REQ below goes out: messages has no replay.
            scope.launch(Dispatchers.Default, start = CoroutineStart.UNDISPATCHED) {
                next.messages.collect { message ->
                    if (!message.contains(prefix)) return@collect
                    eventOf(message, ids)?.let(onEvent)
                }
            },
            // Sent each time it connects: on first open and on every reconnect.
            scope.launch(Dispatchers.Main.immediate) {
                next.connectionState.collect { state ->
                    if (state == WebSocketClient.ConnectionState.CONNECTED) requests.forEach { next.send(it) }
                }
            },
        )
    }

    private fun detach() {
        jobs.forEach { it.cancel() }
        jobs = emptyList()
        val current = client ?: return
        if (owned) {
            current.disconnect()
        } else if (current.connectionState.value == WebSocketClient.ConnectionState.CONNECTED) {
            GlobeStorm.closes(requests).forEach { current.send(it) }
        }
        client = null
        owned = false
    }

    companion object {
        const val RECHECK_MS = 2_000L
        private val json = Json { ignoreUnknownKeys = true }

        /** The event of a relay `EVENT` under one of [ids] (globe subscriptions), or null for anything else. */
        fun eventOf(message: String, ids: Set<String>): JsonObject? {
            val array = runCatching { json.parseToJsonElement(message) as? JsonArray }.getOrNull() ?: return null
            if (array.size < 3) return null
            val type = (array[0] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return null
            val id = (array[1] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return null
            if (type != "EVENT" || id !in ids || !GlobeStorm.isGlobeSubscription(type, id)) return null
            return array[2] as? JsonObject
        }
    }
}
