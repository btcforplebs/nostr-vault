package com.nostrvault.service

import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.NIP10Thread
import com.nostrvault.data.remote.WebSocketClient
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import java.util.UUID

/**
 * Replies arriving while a thread is open (iOS NoteDetailView keeps its replies
 * REQ open past EOSE, so new ones stream in). The one-shot thread fetch
 * ([threadQuery]) reads what is stored; this stays subscribed for what comes
 * next, on the same detail relays, and is closed with the thread.
 */
object LiveThreadReplies {
    /** Overlap with the one-shot fetch, so a reply written as the thread opened isn't missed (merges dedupe by id). */
    const val SINCE_SLACK_SECONDS = 60L

    private val json = Json { ignoreUnknownKeys = true }

    /**
     * The live filters: notes and comments naming the root or the focused note in
     * `e`, comments naming the root in `E`, and comments on an addressable root
     * by `A`. All from [since] on.
     */
    fun filters(rootId: String, focusedId: String, rootCoordinate: String?, since: Long): List<JsonObject> {
        fun arr(values: List<String>) = JsonArray(values.distinct().map(::JsonPrimitive))
        val kinds = JsonArray(listOf(JsonPrimitive(1), JsonPrimitive(NIP10Thread.COMMENT_KIND)))
        return buildList {
            add(buildJsonObject { put("kinds", kinds); put("#e", arr(listOf(rootId, focusedId))); put("since", since) })
            add(buildJsonObject {
                put("kinds", JsonArray(listOf(JsonPrimitive(NIP10Thread.COMMENT_KIND))))
                put("#E", arr(listOf(rootId)))
                put("since", since)
            })
            if (rootCoordinate != null) add(buildJsonObject {
                put("kinds", JsonArray(listOf(JsonPrimitive(NIP10Thread.COMMENT_KIND))))
                put("#A", arr(listOf(rootCoordinate)))
                put("since", since)
            })
        }
    }

    fun request(subId: String, filters: List<JsonObject>): String = buildJsonArray {
        add(JsonPrimitive("REQ"))
        add(JsonPrimitive(subId))
        filters.forEach { add(it) }
    }.toString()

    /**
     * A reply from a relay message under [subId]: a kind 1 note or 1111 comment
     * that isn't noise or spam. Null for anything else (another subscription,
     * EOSE, a malformed event). Pairs it with the raw event JSON for the cache.
     */
    fun replyOf(message: String, subId: String): Pair<FeedNote, String>? {
        val array = runCatching { json.parseToJsonElement(message) as? JsonArray }.getOrNull() ?: return null
        if (array.size < 3) return null
        if ((array[0] as? JsonPrimitive)?.contentOrNull != "EVENT") return null
        if ((array[1] as? JsonPrimitive)?.contentOrNull != subId) return null
        val ev = array[2] as? JsonObject ?: return null
        fun str(key: String) = (ev[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
        val id = str("id") ?: return null
        val pubkey = str("pubkey") ?: return null
        val kind = (ev["kind"] as? JsonPrimitive)?.intOrNull ?: return null
        if (kind != 1 && kind != NIP10Thread.COMMENT_KIND) return null
        val createdAt = (ev["created_at"] as? JsonPrimitive)?.longOrNull ?: return null
        val tags = (ev["tags"] as? JsonArray)?.mapNotNull { tag ->
            (tag as? JsonArray)?.map { (it as? JsonPrimitive)?.contentOrNull ?: return@mapNotNull null }
        }.orEmpty()
        val content = str("content") ?: ""
        if (FeedNote.isNoiseOrSpam(content, tags)) return null
        return FeedNote.fromEvent(id, pubkey, content, tags, createdAt, kind) to ev.toString()
    }
}

/**
 * New replies to an open thread, as they reach the detail relays (local, inbox,
 * read and write relays: the set [queryDetailRelays] asks). One socket per relay,
 * the REQ re-sent on every reconnect; cancelling the collector CLOSEs it and
 * disconnects. Messages are parsed on [Dispatchers.Default].
 */
fun NostrService.liveThreadReplies(
    rootId: String,
    focusedId: String,
    rootCoordinate: String?,
    since: Long = System.currentTimeMillis() / 1000 - LiveThreadReplies.SINCE_SLACK_SECONDS,
): Flow<Pair<FeedNote, String>> = callbackFlow {
    val subId = "live-replies-${UUID.randomUUID().toString().take(8)}"
    val request = LiveThreadReplies.request(subId, LiveThreadReplies.filters(rootId, focusedId, rootCoordinate, since))
    val clients = detailRelayUrls().map { url ->
        WebSocketClient(url = url, scope = this, trustLocalhost = url.contains("localhost") || url.contains("127.0.0.1"))
    }
    for (client in clients) {
        // Both listen before the socket opens: the REQ goes out on CONNECTED, and messages has no replay.
        launch(start = CoroutineStart.UNDISPATCHED) {
            client.messages.collect { message ->
                if (!message.contains(subId)) return@collect
                LiveThreadReplies.replyOf(message, subId)?.let { trySend(it) }
            }
        }
        launch(start = CoroutineStart.UNDISPATCHED) {
            client.connectionState.collect { state ->
                if (state == WebSocketClient.ConnectionState.CONNECTED) client.send(request)
            }
        }
        client.connect()
    }
    awaitClose {
        val close = buildJsonArray { add(JsonPrimitive("CLOSE")); add(JsonPrimitive(subId)) }.toString()
        for (client in clients) {
            runCatching { client.send(close) }
            client.disconnect()
        }
    }
}.flowOn(Dispatchers.Default)
