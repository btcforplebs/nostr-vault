package com.nostrvault.data.remote

import android.util.Log
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.flow.onSubscription
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
    /**
     * A socket another owner already holds open to the relay (the feed's), or
     * null; lookups ride it under [LENT_PREFIX] ids instead of dialling.
     */
    private val lender: ((url: String) -> RelayConnection?)? = null,
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
        lender = { url -> WebSocketClient.lend(url)?.let(::LentConnection) },
    )

    companion object {
        private const val TAG = "LookupSocketPool"
        /** Longer than any lookup window, so a scroll keeps reusing the socket. */
        const val IDLE_MS = 20_000L
        const val COOLDOWN_MS = 120_000L
        /** Same cap the per-lookup sockets had; past it, lookups to new relays are skipped. */
        const val MAX_SOCKETS = 32

        fun relayKey(url: String) = url.trim().trimEnd('/').lowercase()

        /** A live [stream] that lost its socket asks again after this. */
        const val STREAM_RETRY_MS = 5_000L
        /** Frames a lent socket's lookups may queue before its owner's flow waits on them. */
        private const val LENT_BUFFER = 4096

        /**
         * Subscription ids the pool uses on a socket it borrowed from the
         * feed ([WebSocketClient.lend]); the feed skips their frames, and the
         * pool hands them to the caller under the caller's own id.
         */
        const val LENT_PREFIX = "nv-l-"

        /** Whether a frame of [type] for [subId] belongs to a lookup riding a lent socket. */
        fun isLentSubscription(type: String, subId: String): Boolean =
            (type == "EVENT" || type == "EOSE" || type == "CLOSED" || type == "COUNT") && subId.startsWith(LENT_PREFIX)

        /** `["OK", id, accepted, message]` -> accepted and message; null for anything else. */
        internal fun okReply(msg: String): Pair<Boolean, String>? = runCatching {
            val array = kotlinx.serialization.json.Json.parseToJsonElement(msg) as? kotlinx.serialization.json.JsonArray
                ?: return@runCatching null
            fun at(i: Int) = array.getOrNull(i) as? kotlinx.serialization.json.JsonPrimitive
            if (at(0)?.content != "OK") return@runCatching null
            (at(2)?.content == "true") to (at(3)?.content ?: "")
        }.getOrNull()

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
        /** The relay answered a NIP-45 COUNT; nothing left to CLOSE. */
        COUNTED,
        /** The relay answered a published event with OK (accepted or not). */
        OK,
        /** Neither arrived in time; the subscription was CLOSEd. */
        TIMEOUT,
        /** The socket was refused or dropped; the relay is cooling down. */
        FAILED,
        /** Not sent: the relay is cooling down, or the pool is full. */
        SKIPPED,
    }

    private class Sub(val id: String, val endAtEose: Boolean, val onMessage: suspend (String) -> Unit) {
        val done = CompletableDeferred<Outcome>()
        /** The id on the wire: [id] behind [LENT_PREFIX] on a lent socket. */
        var wireId: String = id
        /** A publish's `["OK", id, accepted, message]` answer. */
        @Volatile var reply: Pair<Boolean, String>? = null
    }

    private inner class Entry(val key: String, val connection: RelayConnection) {
        val lent get() = connection.lent
        /** Keyed by wire id. */
        val subs = LinkedHashMap<String, Sub>()
        /** Frames waiting for the handshake, keyed by wire id. */
        val pending = LinkedHashMap<String, String>()
        val subscribed = CompletableDeferred<Unit>()
        var connected = false
        var closed = false
        var idleJob: Job? = null
        val jobs = mutableListOf<Job>()
    }

    private val lock = Any()
    private val entries = HashMap<String, Entry>()
    private val cooldownUntil = HashMap<String, Long>()

    /** Sockets open right now (for tests and diagnostics). Lent ones are another owner's. */
    val openSocketCount: Int get() = synchronized(lock) { entries.values.count { !it.lent } }

    fun isCoolingDown(url: String): Boolean = synchronized(lock) {
        val until = cooldownUntil[relayKey(url)] ?: return false
        until > clock()
    }

    /**
     * Sends `["REQ", subId, ...filters]` to [url] on the relay's pooled socket
     * and hands every frame for that subscription (EVENT, EOSE, CLOSED, ...)
     * to [onMessage], in arrival order. Returns once the relay is done with
     * it or [timeoutMs] passes. With [endAtEose] false it stays open past
     * EOSE (a live subscription) until the relay CLOSEs it, the socket drops,
     * [timeoutMs] passes or the caller is cancelled; see [stream].
     */
    suspend fun query(
        url: String,
        subId: String,
        filters: List<String>,
        timeoutMs: Long,
        /** "COUNT" sends a NIP-45 count instead; it ends at the relay's COUNT reply. */
        verb: String = "REQ",
        endAtEose: Boolean = true,
        onMessage: suspend (String) -> Unit,
    ): Outcome {
        if (filters.isEmpty()) return Outcome.SKIPPED
        val sub = Sub(subId, endAtEose, onMessage)
        val body = filters.joinToString(",")
        val entry = synchronized(lock) {
            register(url, sub) { wire -> "[${quote(verb)},${quote(wire)},$body]" }
        } ?: return Outcome.SKIPPED
        var outcome = Outcome.TIMEOUT
        try {
            outcome = withTimeoutOrNull(timeoutMs) { sub.done.await() } ?: Outcome.TIMEOUT
            return outcome
        } finally {
            synchronized(lock) { unregister(entry, sub, sendClose = outcome == Outcome.TIMEOUT || outcome == Outcome.EOSE) }
        }
    }

    /**
     * A live subscription on [url] until the caller is cancelled: the REQ is
     * sent again on a new socket whenever the old one drops or can't be had,
     * after [retryMs]. Ends early only when the relay CLOSEs it.
     */
    suspend fun stream(
        url: String,
        subId: String,
        filters: List<String>,
        retryMs: Long = STREAM_RETRY_MS,
        onMessage: suspend (String) -> Unit,
    ) {
        while (true) {
            val outcome = query(url, subId, filters, Long.MAX_VALUE, endAtEose = false, onMessage = onMessage)
            if (outcome == Outcome.CLOSED) return
            delay(retryMs)
        }
    }

    /**
     * Sends an event (`["EVENT", ...]`, [eventJson] already signed) to [url]
     * on the relay's pooled socket and waits for its OK; -> accepted and the
     * relay's message. A relay that doesn't answer in [timeoutMs], or can't
     * be reached, counts as not accepted. A second send of the same event to
     * the same relay while the first waits shares the first's answer.
     */
    suspend fun publish(url: String, eventId: String, eventJson: String, timeoutMs: Long): Pair<Boolean, String> {
        val sub = Sub(eventId, endAtEose = false) {}
        val frame = "[\"EVENT\",$eventJson]"
        var joined: Sub? = null
        val entry = synchronized(lock) {
            val key = relayKey(url)
            joined = entries[key]?.takeIf { !it.closed }?.subs?.get(eventId)
            // A post is never skipped for a full pool: it may open one more.
            if (joined != null) null else register(url, sub, wire = eventId, overCap = true) { frame }
        }
        joined?.let { first ->
            withTimeoutOrNull(timeoutMs) { first.done.await() }
            return first.reply ?: (false to "it didn't answer")
        }
        entry ?: return false to "relay unavailable"
        var outcome = Outcome.TIMEOUT
        try {
            outcome = withTimeoutOrNull(timeoutMs) { sub.done.await() } ?: Outcome.TIMEOUT
        } finally {
            synchronized(lock) { unregister(entry, sub, sendClose = false) }
        }
        return sub.reply ?: (false to if (outcome == Outcome.FAILED) "connection failed" else "it didn't answer")
    }

    /** Close every pooled socket (account switch, app teardown). Cooldowns are kept. */
    fun closeAll() {
        val all = synchronized(lock) { entries.values.toList() }
        synchronized(lock) { all.forEach { shut(it) } }
    }

    // ── internals (called with [lock] held unless noted) ──────────────────

    /**
     * Adds [sub] to [url]'s socket and sends [frame] (or holds it for the
     * handshake). [wire] fixes the wire id; by default it is the sub id,
     * behind [LENT_PREFIX] on a lent socket.
     */
    private fun register(
        url: String,
        sub: Sub,
        wire: String? = null,
        overCap: Boolean = false,
        frame: (String) -> String,
    ): Entry? {
        val key = relayKey(url)
        cooldownUntil[key]?.let { until ->
            if (until > clock()) return null
            cooldownUntil.remove(key)
        }
        val entry = entries[key] ?: run {
            val borrowed = lender?.invoke(url)
            if (borrowed == null && !overCap && entries.values.count { !it.lent } >= maxSockets && !evictIdle()) return null
            open(key, borrowed ?: connectionFactory(url))
        }
        // A URL the socket can't even dial fails inside open().
        if (entry.closed) return null
        sub.wireId = wire ?: if (entry.lent) LENT_PREFIX + sub.id else sub.id
        if (entry.subs.containsKey(sub.wireId)) return null
        entry.idleJob?.cancel()
        entry.idleJob = null
        entry.subs[sub.wireId] = sub
        val text = frame(sub.wireId)
        if (entry.connected) entry.connection.send(text) else entry.pending[sub.wireId] = text
        return entry
    }

    private fun unregister(entry: Entry, sub: Sub, sendClose: Boolean) {
        if (entry.subs[sub.wireId] !== sub) return
        entry.subs.remove(sub.wireId)
        if (entry.closed) return
        if (entry.pending.remove(sub.wireId) == null && sendClose) {
            entry.connection.send("[\"CLOSE\",${quote(sub.wireId)}]")
        }
        if (entry.subs.isEmpty()) scheduleIdleClose(entry)
    }

    private fun evictIdle(): Boolean {
        val idle = entries.values.firstOrNull { it.subs.isEmpty() && !it.lent } ?: return false
        shut(idle)
        return true
    }

    private fun open(key: String, connection: RelayConnection): Entry {
        val entry = Entry(key, connection)
        entries[key] = entry
        // Subscribed before connect(): messages has no replay. A lent socket's
        // frames are buffered here, so a slow lookup handler never holds up
        // the owner's own collector (its flow drops frames for everyone when
        // one collector falls behind).
        entry.jobs += scope.launch(start = CoroutineStart.UNDISPATCHED) {
            val frames = entry.connection.messages.onSubscription { entry.subscribed.complete(Unit) }
            (if (entry.lent) frames.buffer(LENT_BUFFER) else frames).collect { msg -> dispatch(entry, msg) }
        }
        entry.connection.connect()
        entry.jobs += scope.launch(start = CoroutineStart.UNDISPATCHED) {
            entry.connection.connectionState.collect { state ->
                when (state) {
                    WebSocketClient.ConnectionState.CONNECTED -> {
                        entry.subscribed.await()
                        synchronized(lock) {
                            if (entry.closed) return@synchronized
                            entry.connected = true
                            entry.pending.values.forEach { entry.connection.send(it) }
                            entry.pending.clear()
                            if (entry.subs.isEmpty()) scheduleIdleClose(entry)
                        }
                    }
                    // connect() has been called, so DISCONNECTED here means the
                    // relay refused, timed out or dropped us. Ours set closed first.
                    WebSocketClient.ConnectionState.DISCONNECTED -> fail(entry)
                    // A lent socket the owner is redialling is gone already.
                    else -> if (entry.lent) fail(entry)
                }
            }
        }
        // The owner swapped in a new socket (a redial StateFlow folded into
        // one CONNECTED): our subscriptions died with the old one.
        if (connection.lent) connection.generation?.let { generation ->
            val first = generation.value
            entry.jobs += scope.launch(start = CoroutineStart.UNDISPATCHED) {
                generation.collect { if (it != first) fail(entry) }
            }
        }
        return entry
    }

    /** Not under [lock]: handlers may suspend. */
    private suspend fun dispatch(entry: Entry, msg: String) {
        val (type, wireId) = route(msg) ?: return
        val sub = synchronized(lock) { entry.subs[wireId] } ?: return
        if (type == "OK") {
            sub.reply = okReply(msg)
            sub.done.complete(Outcome.OK)
            return
        }
        val forCaller = if (wireId == sub.id) msg else msg.replaceFirst(quote(wireId), quote(sub.id))
        try {
            sub.onMessage(forCaller)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "Lookup handler failed: ${e.message}")
        }
        when (type) {
            "EOSE" -> if (sub.endAtEose) sub.done.complete(Outcome.EOSE)
            "CLOSED" -> sub.done.complete(Outcome.CLOSED)
            "COUNT" -> sub.done.complete(Outcome.COUNTED)
        }
    }

    private fun fail(entry: Entry) {
        synchronized(lock) {
            if (entry.closed) return
            // A lent socket is the owner's to redial; the next lookup borrows
            // its new one or opens ours.
            if (!entry.lent) cooldownUntil[entry.key] = clock() + cooldownMs
            shut(entry)
        }
        Log.d(TAG, "Lookup socket to ${entry.key} refused or dropped")
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
        // Lent: CLOSE ours, leave the owner's socket be.
        if (entry.lent) {
            entry.subs.values.filter { it.endAtEose || it.wireId != it.id }.forEach {
                entry.connection.send("[\"CLOSE\",${quote(it.wireId)}]")
            }
        }
        entry.subs.clear()
        entry.connection.disconnect()
    }

    private fun quote(s: String) = "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
}
