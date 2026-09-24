package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.GlobalSearchAccumulator
import com.nostrvault.data.model.GlobalSearchResults
import com.nostrvault.data.model.GlobalSearchState
import com.nostrvault.data.model.LocalRelaySearchPlan
import com.nostrvault.data.model.Nip11
import com.nostrvault.data.model.SearchRelayUrls
import com.nostrvault.data.model.SearchSourceKind
import com.nostrvault.data.model.SearchSourceState
import com.nostrvault.data.model.SearchSourceStatus
import com.nostrvault.data.model.SearchTermMatcher
import com.nostrvault.data.model.SearchWireMessage
import com.nostrvault.data.model.finalSourceStatus
import com.nostrvault.data.model.parseProfileMetadata
import com.nostrvault.data.remote.WebSocketClient
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.io.IOException
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * One search across every source at once: the phone's embedded relay, the Mac
 * relay (if configured) and the NIP-50 search relays. Each source runs on its
 * own sockets, results stream into [state] as they land (deduplicated by event
 * id / pubkey, ranked own → follows → everyone, newest first), and every source
 * ends on its own EOSE / CLOSED / error, with a hard cap of [SOURCE_TIMEOUT_MS].
 *
 * A session is single-use: [start] once, [cancel] when the query changes.
 */
class GlobalSearchSession(
    private val query: String,
    private val matcher: SearchTermMatcher,
    private val plan: Plan,
    private val own: Set<String>,
    private val follows: Set<String>,
    private val cachedProfiles: Collection<FeedProfile> = emptyList(),
    private val onFinished: (GlobalSearchResults) -> Unit = {},
) {
    /**
     * @param phoneRelayUrl base ws URL of the embedded relay; null skips it.
     * @param macRelayUrl base wss URL of the Mac relay; null skips it.
     * @param searchRelays NIP-50 services.
     */
    data class Plan(
        val phoneRelayUrl: String?,
        val macRelayUrl: String?,
        val searchRelays: List<String>,
    )

    companion object {
        private const val TAG = "GlobalSearchSession"

        /** Hard cap per source; the normal end is EOSE / CLOSED. */
        const val SOURCE_TIMEOUT_MS = 15_000L
        private const val NIP11_TIMEOUT_MS = 4_000L
        private const val PUBLISH_INTERVAL_MS = 150L

        private const val SERVICE_NOTE_LIMIT = 50
        private const val SERVICE_PROFILE_LIMIT = 30
        private const val MAC_NOTE_LIMIT = 300
        private const val MAC_PROFILE_LIMIT = 100

        /** haven's publicly readable routes: outbox, follows' notes, notes tagging the owner. */
        val READABLE_ROUTES = listOf("", "/feed", "/inbox")

        const val PHONE_SOURCE_ID = "phone"
        const val MAC_SOURCE_ID = "mac"

        private fun isLocalHost(url: String): Boolean =
            SearchRelayUrls.isLocalNetworkHost(url.substringAfter("://").substringBefore('/').substringBefore(':'))

        private fun httpClientFor(url: String): OkHttpClient =
            if (isLocalHost(url)) WebSocketClient.sharedLocalhostClient else WebSocketClient.sharedClient
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lock = Any()
    private val accumulator = GlobalSearchAccumulator()
    private val sources: MutableList<SearchSourceState> = buildList {
        if (plan.phoneRelayUrl != null) {
            add(SearchSourceState(PHONE_SOURCE_ID, "Phone", SearchSourceKind.PHONE))
        }
        if (plan.macRelayUrl != null) {
            add(SearchSourceState(MAC_SOURCE_ID, "Mac relay", SearchSourceKind.MAC))
        }
        plan.searchRelays.distinct().forEach { url ->
            add(SearchSourceState(url, SearchRelayUrls.label(url), SearchSourceKind.RELAY))
        }
    }.toMutableList()
    /** Result keys each source returned, so a chip counts what that source found, not what was new. */
    private val sourceKeys = HashMap<String, MutableSet<String>>()
    private val dirty = AtomicBoolean(false)
    private val started = AtomicBoolean(false)
    private val subCounter = AtomicInteger(0)
    @Volatile private var cancelled = false

    /** The final results, once the session has finished (null before, or if cancelled first). */
    @Volatile var finishedResults: GlobalSearchResults? = null
        private set

    private val _state = MutableStateFlow(GlobalSearchState(sources = sources.toList(), isRunning = true))
    val state: StateFlow<GlobalSearchState> = _state.asStateFlow()

    fun start() {
        if (!started.compareAndSet(false, true)) return

        if (plan.phoneRelayUrl != null) addCachedProfiles()

        val workers = sources.map { src -> scope.launch { runSource(src) } }
        val publisher = scope.launch {
            while (isActive) {
                delay(PUBLISH_INTERVAL_MS)
                if (dirty.getAndSet(false)) publish(running = true)
            }
        }
        scope.launch {
            workers.joinAll()
            // The publisher must be gone before the final publish, or a tick
            // landing after it re-publishes isRunning = true and it sticks.
            publisher.cancelAndJoin()
            dirty.set(false)
            if (cancelled) return@launch
            val results = publish(running = false)
            finishedResults = results
            try { onFinished(results) } catch (e: Exception) { Log.w(TAG, "onFinished: ${e.message}") }
            scope.cancel()
        }
    }

    fun cancel() {
        cancelled = true
        scope.cancel()
    }

    // ── Sources ──────────────────────────────────────────────────────

    /** Sticky facts about how a source's sockets ended; see [finalSourceStatus]. */
    private class Outcome {
        @Volatile var answered = false
        @Volatile var closedReason: String? = null
        @Volatile var error: String? = null
    }

    private suspend fun runSource(src: SearchSourceState) {
        val outcome = Outcome()
        val finished = withTimeoutOrNull(SOURCE_TIMEOUT_MS) {
            when (src.kind) {
                SearchSourceKind.PHONE -> runPaged(
                    src.id,
                    READABLE_ROUTES.map { plan.phoneRelayUrl!!.trimEnd('/') + it },
                    outcome,
                )
                SearchSourceKind.MAC -> runMac(src.id, plan.macRelayUrl!!.trimEnd('/'), outcome)
                SearchSourceKind.RELAY -> runNip50(
                    src.id, listOf(src.id), outcome,
                    verify = false,
                    noteLimit = SERVICE_NOTE_LIMIT,
                    profileLimit = SERVICE_PROFILE_LIMIT,
                )
            }
            true
        }
        if (cancelled) return
        val count = synchronized(lock) { sourceKeys[src.id]?.size ?: 0 }
        val status = finalSourceStatus(
            count = count,
            answered = outcome.answered,
            timedOut = finished == null,
            closedReason = outcome.closedReason,
            error = outcome.error,
        )
        updateSource(src.id) { it.copy(status = status, count = count) }
    }

    /**
     * The Mac relay: NIP-50 if its NIP-11 advertises 50 (still verified — an own
     * store must only return real matches), otherwise walked page by page like
     * the phone store.
     */
    private suspend fun runMac(sourceId: String, base: String, outcome: Outcome) {
        val nip50 = fetchSupportsNip50(base)
        updateSource(sourceId) { it.copy(detail = if (nip50) "NIP-50" else "scan") }
        val routes = READABLE_ROUTES.map { base + it }
        if (nip50) {
            runNip50(sourceId, routes, outcome, verify = true,
                noteLimit = MAC_NOTE_LIMIT, profileLimit = MAC_PROFILE_LIMIT)
        } else {
            runPaged(sourceId, routes, outcome)
        }
    }

    private suspend fun fetchSupportsNip50(wsBase: String): Boolean {
        val url = Nip11.httpUrl(wsBase)
        val client = httpClientFor(wsBase).newBuilder()
            .callTimeout(NIP11_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            .build()
        return try {
            val request = Request.Builder().url(url).header("Accept", "application/nostr+json").build()
            runInterruptible(Dispatchers.IO) {
                client.newCall(request).execute().use { resp ->
                    resp.isSuccessful && Nip11.supportsNip50(resp.body?.string().orEmpty())
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.d(TAG, "NIP-11 $url: ${e.message}")
            false
        }
    }

    /** Separate REQs for kind 0 and kind 1 on every route, so a profile-only relay CLOSING the notes REQ keeps its profiles. */
    private suspend fun runNip50(
        sourceId: String,
        routes: List<String>,
        outcome: Outcome,
        verify: Boolean,
        noteLimit: Int,
        profileLimit: Int,
    ) = coroutineScope {
        for (url in routes) {
            launch { nip50Route(sourceId, url, outcome, verify, noteLimit, profileLimit) }
        }
    }

    private suspend fun nip50Route(
        sourceId: String,
        url: String,
        outcome: Outcome,
        verify: Boolean,
        noteLimit: Int,
        profileLimit: Int,
    ) {
        val socket = SearchSocket.open(url, httpClientFor(url)) ?: run {
            outcome.error = "invalid URL"
            return
        }
        try {
            socket.awaitOpen()
            val subs = HashSet<String>()
            for ((kind, limit) in listOf(0 to profileLimit, 1 to noteLimit)) {
                val sid = newSubId("gs$kind")
                subs.add(sid)
                val filter = buildJsonObject {
                    put("kinds", JsonArray(listOf(JsonPrimitive(kind))))
                    put("search", query)
                    put("limit", limit)
                }
                socket.send("[\"REQ\",${JsonPrimitive(sid)},$filter]")
            }
            for (msg in socket.incoming) {
                when (val m = SearchWireMessage.parse(msg)) {
                    is SearchWireMessage.Event -> if (m.subId in subs) accept(sourceId, m, verify)
                    is SearchWireMessage.Eose -> if (subs.remove(m.subId)) {
                        outcome.answered = true
                        socket.send("[\"CLOSE\",${JsonPrimitive(m.subId)}]")
                    }
                    is SearchWireMessage.Closed -> if (subs.remove(m.subId)) {
                        outcome.closedReason = m.reason
                    }
                    else -> Unit
                }
                if (subs.isEmpty()) break
            }
            if (subs.isNotEmpty()) outcome.error = outcome.error ?: "connection closed"
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            outcome.error = e.message ?: "connection failed"
        } finally {
            socket.close()
        }
    }

    /**
     * A store without NIP-50: every route, kinds 0 and 1, paged with an
     * `until` cursor under the backend's limit cap, each event checked against
     * the query on-device.
     */
    private suspend fun runPaged(sourceId: String, routes: List<String>, outcome: Outcome) = coroutineScope {
        for (url in routes) {
            launch { pagedRoute(sourceId, url, outcome) }
        }
    }

    private class PageStream(val kind: Int, val page: Int, val until: Long?) {
        var received = 0
        var newIds = 0
        var oldest: Long? = null
    }

    private suspend fun pagedRoute(sourceId: String, url: String, outcome: Outcome) {
        val socket = SearchSocket.open(url, httpClientFor(url)) ?: run {
            outcome.error = "invalid URL"
            return
        }
        try {
            socket.awaitOpen()
            val streams = HashMap<String, PageStream>()
            val seen = HashSet<String>()

            fun sendPage(kind: Int, page: Int, until: Long?) {
                val sid = newSubId("gp$kind")
                streams[sid] = PageStream(kind, page, until)
                val filter = buildJsonObject {
                    put("kinds", JsonArray(listOf(JsonPrimitive(kind))))
                    put("limit", LocalRelaySearchPlan.PAGE_LIMIT)
                    if (until != null) put("until", until)
                }
                socket.send("[\"REQ\",${JsonPrimitive(sid)},$filter]")
            }

            sendPage(0, 1, null)
            sendPage(1, 1, null)

            for (msg in socket.incoming) {
                when (val m = SearchWireMessage.parse(msg)) {
                    is SearchWireMessage.Event -> {
                        val stream = streams[m.subId]
                        if (stream != null) {
                            stream.received++
                            stream.oldest = stream.oldest?.let { minOf(it, m.createdAt) } ?: m.createdAt
                            if (seen.add(m.id)) {
                                stream.newIds++
                                accept(sourceId, m, verify = true)
                            }
                        }
                    }
                    is SearchWireMessage.Eose -> {
                        val stream = streams.remove(m.subId)
                        if (stream != null) {
                            outcome.answered = true
                            socket.send("[\"CLOSE\",${JsonPrimitive(m.subId)}]")
                            val step = LocalRelaySearchPlan.step(
                                received = stream.received,
                                newIds = stream.newIds,
                                oldestCreatedAt = stream.oldest,
                                pagesFetched = stream.page,
                                requestedUntil = stream.until,
                            )
                            if (step is LocalRelaySearchPlan.Step.Next) {
                                sendPage(stream.kind, stream.page + 1, step.until)
                            }
                        }
                    }
                    is SearchWireMessage.Closed -> {
                        if (streams.remove(m.subId) != null) outcome.closedReason = m.reason
                    }
                    else -> Unit
                }
                if (streams.isEmpty()) break
            }
            if (streams.isNotEmpty()) outcome.error = outcome.error ?: "connection closed"
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            outcome.error = e.message ?: "connection failed"
        } finally {
            socket.close()
        }
    }

    private fun newSubId(prefix: String): String =
        "$prefix-${subCounter.incrementAndGet()}-${UUID.randomUUID().toString().take(6)}"

    // ── Merge ────────────────────────────────────────────────────────

    /**
     * No local store holds most people's kind 0, so the phone source also
     * matches profiles the app already has cached (iOS does the same).
     */
    private fun addCachedProfiles() {
        synchronized(lock) {
            for (p in cachedProfiles) {
                if (!matcher.matchesProfile(p)) continue
                accumulator.addProfile(p, createdAt = 0L)
                sourceKeys.getOrPut(PHONE_SOURCE_ID) { HashSet() }.add("p:${p.pubkey}")
            }
            dirty.set(true)
        }
    }

    private fun accept(sourceId: String, ev: SearchWireMessage.Event, verify: Boolean) {
        when (ev.kind) {
            1 -> {
                if (verify && !matcher.matchesNote(ev.content, ev.tags)) return
                val note = FeedNote.fromEvent(ev.id, ev.pubkey, ev.content, ev.tags, ev.createdAt, ev.kind)
                synchronized(lock) {
                    accumulator.addNote(note)
                    sourceKeys.getOrPut(sourceId) { HashSet() }.add("n:${ev.id}")
                    bumpCount(sourceId)
                }
                dirty.set(true)
            }
            0 -> {
                val profile = parseProfileMetadata(ev.pubkey, ev.content) ?: return
                if (verify && !matcher.matchesProfileContent(ev.content, ev.pubkey)) return
                synchronized(lock) {
                    accumulator.addProfile(profile, ev.createdAt)
                    sourceKeys.getOrPut(sourceId) { HashSet() }.add("p:${ev.pubkey}")
                    bumpCount(sourceId)
                }
                dirty.set(true)
            }
        }
    }

    /** Caller holds [lock]. Live count while a source is still searching. */
    private fun bumpCount(sourceId: String) {
        val i = sources.indexOfFirst { it.id == sourceId }
        if (i >= 0) sources[i] = sources[i].copy(count = sourceKeys[sourceId]?.size ?: 0)
    }

    private fun updateSource(sourceId: String, transform: (SearchSourceState) -> SearchSourceState) {
        synchronized(lock) {
            val i = sources.indexOfFirst { it.id == sourceId }
            if (i >= 0) sources[i] = transform(sources[i])
        }
        dirty.set(true)
    }

    private fun publish(running: Boolean): GlobalSearchResults = synchronized(lock) {
        val results = accumulator.ranked(own, follows)
        if (!cancelled) {
            _state.value = GlobalSearchState(results = results, sources = sources.toList(), isRunning = running)
        }
        results
    }
}

/**
 * A one-shot relay socket for search: no reconnects (a search that loses its
 * socket reports it, rather than retrying for two minutes), messages delivered
 * through a channel that closes — with the failure — when the socket does.
 */
private class SearchSocket private constructor(url: String, http: OkHttpClient) {
    val incoming = Channel<String>(Channel.UNLIMITED)
    private val opened = CompletableDeferred<Unit>()
    private val ws: WebSocket

    init {
        val request = Request.Builder().url(url).build()
        ws = http.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                opened.complete(Unit)
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                incoming.trySend(text)
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                webSocket.close(1000, null)
                val e = IOException("closed by relay ($code${if (reason.isNotBlank()) ": $reason" else ""})")
                opened.completeExceptionally(e)
                incoming.close(e)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                incoming.close()
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                val msg = when {
                    response != null -> "HTTP ${response.code}"
                    t.message.isNullOrBlank() -> t.javaClass.simpleName
                    else -> t.message!!
                }
                val e = IOException(msg)
                opened.completeExceptionally(e)
                incoming.close(e)
            }
        })
    }

    suspend fun awaitOpen() = opened.await()

    fun send(text: String) {
        ws.send(text)
    }

    fun close() {
        ws.cancel()
        incoming.close()
    }

    companion object {
        fun open(url: String, http: OkHttpClient): SearchSocket? = try {
            SearchSocket(url, http)
        } catch (_: IllegalArgumentException) {
            null
        }
    }
}
