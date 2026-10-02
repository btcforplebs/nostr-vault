package com.nostrvault.data.remote

import android.util.Log
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import javax.inject.Inject
import javax.inject.Singleton

/**
 * One socket per relay for one-shot lookups (missing notes, thread roots,
 * quotes, engagement, relay lists, note detail), reused across lookups and
 * closed once it has gone quiet. Port of iOS #125.
 *
 * Each lookup used to open a fresh socket to every relay it asked and drop it
 * when its window ran out. Scrolling a threaded feed looks up every few
 * hundred ms, so the same ~20 relays were redialled over and over; on iOS
 * that was ~500 WebSocket upgrades a minute, half of them refused with HTTP
 * 429, and the phone ran hot. Now:
 *  - a relay gets one socket, and every lookup to it is a REQ on that socket
 *    under its own subscription id;
 *  - REQs sent during the handshake wait for it;
 *  - a lookup ends at its EOSE or CLOSED, or at its timeout (then we CLOSE it);
 *  - the socket closes [idleMs] after its last lookup ends;
 *  - a relay that refuses or drops the socket (a 429 included) gets no new
 *    socket for [cooldownMs]; lookups to it in that time are skipped.
 */
@Singleton
class LookupSocketPool(
    private val scope: CoroutineScope,
    private val connectionFactory: (url: String) -> RelayConnection,
    private val clock: () -> Long = System::currentTimeMillis,
    private val idleMs: Long = IDLE_MS,
    private val cooldownMs: Long = COOLDOWN_MS,
    private val maxSockets: Int = MAX_SOCKETS,
) {
    @Inject constructor() : this(
        scope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
        connectionFactory = { url ->
            WebSocketClient(
                url = url,
                scope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
                trustLocalhost = url.contains("localhost") || url.contains("127.0.0.1"),
                autoReconnect = false,
                // One collector handles every lookup on this relay, and note
                // lookups verify each event inline; give it room so a burst
                // doesn't drop frames (an EOSE included).
                messageBuffer = 4096,
            )
        },
    )

    companion object {
        private const val TAG = "LookupSocketPool"
        /** Longer than any lookup window, so a scroll keeps reusing the socket. */
        const val IDLE_MS = 20_000L
        const val COOLDOWN_MS = 120_000L
        /** Same cap the per-lookup sockets had; past it, lookups to new relays are skipped. */
        const val MAX_SOCKETS = 32

        fun relayKey(url: String) = url.trim().trimEnd('/').lowercase()

        /**
         * Message type and subscription id of a relay frame like
         * `["EVENT","sub",{...}]`, read without parsing the event.
         */
        internal fun route(msg: String): Pair<String, String>? {
            var i = msg.indexOf('[')
            if (i < 0) return null
            val type = readString(msg, i + 1) ?: return null
            i = type.second
            while (i < msg.length && (msg[i] == ' ' || msg[i] == ',' || msg[i] == '\n' || msg[i] == '\t' || msg[i] == '\r')) i++
            val sub = readString(msg, i) ?: return null
            return type.first to sub.first
        }

        /** The JSON string starting at or after [from] (whitespace only), and the index past it. */
        private fun readString(s: String, from: Int): Pair<String, Int>? {
            var i = from
            while (i < s.length && s[i].isWhitespace()) i++
            if (i >= s.length || s[i] != '"') return null
            val sb = StringBuilder()
            i++
            while (i < s.length) {
                val c = s[i]
                when (c) {
                    '"' -> return sb.toString() to i + 1
                    '\\' -> {
                        if (i + 1 >= s.length) return null
                        sb.append(s[i + 1])
                        i += 2
                    }
                    else -> { sb.append(c); i++ }
                }
            }
            return null
        }
    }

    enum class Outcome {
        /** The relay sent EOSE. */
        EOSE,
        /** The relay sent CLOSED for the subscription. */
        CLOSED,
        /** Neither arrived in time; the subscription was CLOSEd. */
        TIMEOUT,
        /** The socket was refused or dropped; the relay is cooling down. */
        FAILED,
        /** Not sent: the relay is cooling down, or the pool is full. */
        SKIPPED,
    }

    private class Sub(val id: String, val onMessage: suspend (String) -> Unit) {
        val done = CompletableDeferred<Outcome>()
    }

    private inner class Entry(val key: String, val connection: RelayConnection) {
        val subs = LinkedHashMap<String, Sub>()
        /** REQ frames waiting for the handshake. */
        val pending = LinkedHashMap<String, String>()
        var connected = false
        var closed = false
        var idleJob: Job? = null
        val jobs = mutableListOf<Job>()
    }

    private val lock = Any()
    private val entries = HashMap<String, Entry>()
    private val cooldownUntil = HashMap<String, Long>()

    /** Sockets open right now (for tests and diagnostics). */
    val openSocketCount: Int get() = synchronized(lock) { entries.size }

    fun isCoolingDown(url: String): Boolean = synchronized(lock) {
        val until = cooldownUntil[relayKey(url)] ?: return false
        until > clock()
    }

    /**
     * Sends `["REQ", subId, ...filters]` to [url] on the relay's pooled socket
     * and hands every frame for that subscription (EVENT, EOSE, CLOSED, ...)
     * to [onMessage], in arrival order. Returns once the relay is done with
     * it or [timeoutMs] passes.
     */
    suspend fun query(
        url: String,
        subId: String,
        filters: List<String>,
        timeoutMs: Long,
        onMessage: suspend (String) -> Unit,
    ): Outcome {
        if (filters.isEmpty()) return Outcome.SKIPPED
        val sub = Sub(subId, onMessage)
        val req = "[\"REQ\",${quote(subId)},${filters.joinToString(",")}]"
        val entry = synchronized(lock) { register(url, sub, req) } ?: return Outcome.SKIPPED
        var outcome = Outcome.TIMEOUT
        try {
            outcome = withTimeoutOrNull(timeoutMs) { sub.done.await() } ?: Outcome.TIMEOUT
            return outcome
        } finally {
            synchronized(lock) { unregister(entry, sub, sendClose = outcome == Outcome.TIMEOUT || outcome == Outcome.EOSE) }
        }
    }

    /** Close every pooled socket (account switch, app teardown). Cooldowns are kept. */
    fun closeAll() {
        val all = synchronized(lock) { entries.values.toList() }
        synchronized(lock) { all.forEach { shut(it) } }
    }

    // ── internals (called with [lock] held unless noted) ──────────────────

    private fun register(url: String, sub: Sub, req: String): Entry? {
        val key = relayKey(url)
        cooldownUntil[key]?.let { until ->
            if (until > clock()) return null
            cooldownUntil.remove(key)
        }
        val entry = entries[key] ?: run {
            if (entries.size >= maxSockets && !evictIdle()) return null
            open(key, url)
        }
        // A URL the socket can't even dial fails inside open().
        if (entry.closed) return null
        if (entry.subs.containsKey(sub.id)) return null
        entry.idleJob?.cancel()
        entry.idleJob = null
        entry.subs[sub.id] = sub
        if (entry.connected) entry.connection.send(req) else entry.pending[sub.id] = req
        return entry
    }

    private fun unregister(entry: Entry, sub: Sub, sendClose: Boolean) {
        if (entry.subs[sub.id] !== sub) return
        entry.subs.remove(sub.id)
        if (entry.closed) return
        if (entry.pending.remove(sub.id) == null && sendClose) {
            entry.connection.send("[\"CLOSE\",${quote(sub.id)}]")
        }
        if (entry.subs.isEmpty()) scheduleIdleClose(entry)
    }

    private fun evictIdle(): Boolean {
        val idle = entries.values.firstOrNull { it.subs.isEmpty() } ?: return false
        shut(idle)
        return true
    }

    private fun open(key: String, url: String): Entry {
        val entry = Entry(key, connectionFactory(url))
        entries[key] = entry
        // Subscribed before connect(): messages has no replay.
        entry.jobs += scope.launch(start = CoroutineStart.UNDISPATCHED) {
            entry.connection.messages.collect { msg -> dispatch(entry, msg) }
        }
        entry.connection.connect()
        entry.jobs += scope.launch(start = CoroutineStart.UNDISPATCHED) {
            entry.connection.connectionState.collect { state ->
                when (state) {
                    WebSocketClient.ConnectionState.CONNECTED -> synchronized(lock) {
                        if (entry.closed) return@synchronized
                        entry.connected = true
                        entry.pending.values.forEach { entry.connection.send(it) }
                        entry.pending.clear()
                        if (entry.subs.isEmpty()) scheduleIdleClose(entry)
                    }
                    // connect() has been called, so DISCONNECTED here means the
                    // relay refused, timed out or dropped us. Ours set closed first.
                    WebSocketClient.ConnectionState.DISCONNECTED -> fail(entry)
                    else -> {}
                }
            }
        }
        return entry
    }

    /** Not under [lock]: handlers may suspend. */
    private suspend fun dispatch(entry: Entry, msg: String) {
        val (type, subId) = route(msg) ?: return
        val sub = synchronized(lock) { entry.subs[subId] } ?: return
        try {
            sub.onMessage(msg)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "Lookup handler failed: ${e.message}")
        }
        when (type) {
            "EOSE" -> sub.done.complete(Outcome.EOSE)
            "CLOSED" -> sub.done.complete(Outcome.CLOSED)
        }
    }

    private fun fail(entry: Entry) {
        synchronized(lock) {
            if (entry.closed) return
            cooldownUntil[entry.key] = clock() + cooldownMs
            shut(entry)
        }
        Log.d(TAG, "Lookup socket to ${entry.key} refused or dropped; cooling down")
    }

    private fun scheduleIdleClose(entry: Entry) {
        entry.idleJob?.cancel()
        entry.idleJob = scope.launch {
            delay(idleMs)
            synchronized(lock) {
                if (entry.subs.isEmpty() && !entry.closed) shut(entry)
            }
        }
    }

    /** Remove and disconnect, with [lock] held. Lookups still open on it end as FAILED. */
    private fun shut(entry: Entry) {
        if (entry.closed) return
        entry.closed = true
        if (entries[entry.key] === entry) entries.remove(entry.key)
        entry.idleJob?.cancel()
        entry.jobs.forEach { it.cancel() }
        entry.pending.clear()
        entry.subs.values.forEach { it.done.complete(Outcome.FAILED) }
        entry.connection.disconnect()
    }

    private fun quote(s: String) = "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
}
