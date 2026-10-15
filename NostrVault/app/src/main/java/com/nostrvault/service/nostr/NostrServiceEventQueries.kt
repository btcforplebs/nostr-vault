package com.nostrvault.service

import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.remote.LookupSocketPool
import com.nostrvault.data.remote.WebSocketClient
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlin.concurrent.withLock
import com.nostrvault.service.NostrService.Companion.TEMP_CLIENT_DISCONNECT_MS
import com.nostrvault.service.NostrService.Companion.countFrom

    internal fun NostrService.fetchThreadImpl(
        rootId: String,
        focusedId: String,
        ancestorIds: List<String>,
        rootCoordinate: String? = null,
        onRawEvent: ((String, String) -> Unit)? = null,
        onResult: (List<FeedNote>) -> Unit,
    ) = threadQuery(rootId, focusedId, ancestorIds, rootCoordinate, onRawEvent, onResult)

    internal fun NostrService.fetchNoteByIdImpl(
        id: String,
        onRawEvent: ((String, String) -> Unit)? = null,
        onResult: (FeedNote?) -> Unit,
    ) {
        val delivered = java.util.concurrent.atomic.AtomicBoolean(false)
        // No kinds: pictures, videos, highlights and articles open by id too.
        // Only the asked-for id is kept, so nothing else can slip in.
        queryDetailRelays(listOf("""{"ids":["$id"]}"""), onRawEvent, acceptKinds = null) { notes ->
            val match = notes.firstOrNull { it.id == id }
            if (match != null && delivered.compareAndSet(false, true)) onResult(match)
        }
        scope.launch {
            delay(TEMP_CLIENT_DISCONNECT_MS + 1000)
            if (delivered.compareAndSet(false, true)) onResult(null)
        }
    }

    internal fun NostrService.fetchRepliesForImpl(
        noteIds: List<String>,
        onRawEvent: ((String, String) -> Unit)? = null,
        onResult: (List<FeedNote>) -> Unit,
    ) {
        if (noteIds.isEmpty()) { onResult(emptyList()); return }
        val idArr = noteIds.distinct().joinToString(",") { "\"$it\"" }
        queryDetailRelays(
            listOf("""{"kinds":[1,$COMMENT],"#e":[$idArr],"limit":150}"""),
            onRawEvent,
            onEose = onResult,
        )
    }

    internal suspend fun NostrService.queryRawEventsImpl(
        filters: List<String>,
        relayUrls: List<String>,
        timeoutMs: Long = 5_000L,
        onAnswered: (() -> Unit)? = null,
        onProgress: ((List<JsonObject>) -> Unit)? = null,
    ): List<JsonObject> {
        if (filters.isEmpty() || relayUrls.isEmpty()) return emptyList()
        val subId = "q-${UUID.randomUUID().toString().take(8)}"
        val collected = ConcurrentHashMap<String, JsonObject>()

        // Each relay's lookup ends at its EOSE/CLOSED, or at once when the
        // relay refuses the socket (or refused one in the last two minutes).
        withTimeoutOrNull(timeoutMs) {
            coroutineScope {
                for (relayUrl in relayUrls) launch(Dispatchers.IO) {
                    val outcome = lookupPool.query(relayUrl, subId, filters, timeoutMs) { msg ->
                        handleRawQueryMessage(msg, subId, collected)
                    }
                    if (outcome == LookupSocketPool.Outcome.EOSE) onAnswered?.invoke()
                    // What has arrived so far, as each relay finishes, so a
                    // caller need not wait for the slowest one.
                    if (onProgress != null && collected.isNotEmpty()) onProgress(collected.values.toList())
                }
            }
        }
        return collected.values.toList()
    }

    /**
     * NIP-45 COUNT for [filter] on one relay, on the pooled lookup socket.
     * Null when the relay refuses COUNT (most do), doesn't answer in
     * [timeoutMs], or sends no number.
     */
    internal suspend fun NostrService.countEventsImpl(relayUrl: String, filter: Map<String, Any>, timeoutMs: Long = 8_000L): Int? {
        if (!isValidRelayUrl(relayUrl)) return null
        val subId = "count-${UUID.randomUUID().toString().take(8)}"
        var count: Int? = null
        lookupPool.query(relayUrl, subId, listOf(buildFilterJson(filter)), timeoutMs, verb = "COUNT") { msg ->
            count = countFrom(msg) ?: count
        }
        return count
    }

    internal fun NostrService.fetchNotesByIdsImpl(ids: List<String>, relayUrls: List<String>) {
        val subId = "ids-${UUID.randomUUID().toString().take(8)}"
        val filter = buildMap<String, Any> {
            put("ids", ids)
        }

        for (relayUrl in relayUrls) {
            scope.launch(Dispatchers.IO) {
                lookupPool.query(relayUrl, subId, listOf(buildFilterJson(filter)), TEMP_CLIENT_DISCONNECT_MS) { msg ->
                    launch(Dispatchers.Default) { processRelayMessage(msg, relayUrl) }
                }
            }
        }
    }

    /** [tagFilter] narrows the request, e.g. `"#P" to listOf(me)` for zaps you sent. */
    internal fun NostrService.fetchZapReceiptsImpl(relayUrls: List<String>, limit: Int = 1000, tagFilter: Map<String, List<String>> = emptyMap()) {
        val subId = "zaps-${UUID.randomUUID().toString().take(8)}"
        val filter = buildFilterJson(buildMap<String, Any> {
            put("kinds", listOf(9735))
            put("limit", limit)
            putAll(tagFilter)
        })

        for (relayUrl in relayUrls) {
            scope.launch(Dispatchers.IO) {
                val client = WebSocketClient(url = relayUrl, scope = scope)
                tempClientsLock.withLock { temporaryClients.add(client) }

                scope.launch(Dispatchers.Default) {
                    client.messages.collect { msg ->
                        launch(Dispatchers.Default) {
                            processRelayMessage(msg, relayUrl)
                        }
                    }
                }

                client.connect()
                client.send("[\"REQ\",\"$subId\",$filter]")

                delay(TEMP_CLIENT_DISCONNECT_MS)
                client.disconnect()
                tempClientsLock.withLock { temporaryClients.remove(client) }
            }
        }
    }
