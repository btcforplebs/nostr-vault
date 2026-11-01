package com.nostrvault.data.remote

import android.util.Log
import com.nostrvault.BuildConfig
import com.nostrvault.data.remote.LocalTls.localTrust
import com.nostrvault.relay.RelayBlocklist
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.concurrent.TimeUnit

/**
 * Port of WebSocketClient.swift -- OkHttp WebSocket with auto-reconnect.
 *
 * Features:
 * - Our own idle watchdog instead of OkHttp pings (see [WATCHDOG_IDLE_MS])
 * - Exponential backoff reconnection (up to 10 attempts)
 * - Localhost trust for self-signed certs (local relay, LAN)
 * - SharedFlow for message delivery (replaces Combine PassthroughSubject)
 * - StateFlow for connection state
 */
class WebSocketClient(
    private val url: String,
    private val scope: CoroutineScope,
    private val trustLocalhost: Boolean = false,
    /**
     * False for pooled lookup sockets: a failure there is final, and
     * [LookupSocketPool] decides when to dial the relay again.
     */
    private val autoReconnect: Boolean = true,
    /** Frames held for a slow collector before new ones are dropped. */
    messageBuffer: Int = 256,
    /**
     * Other features may borrow this socket while it is open ([lend]): the
     * feed's, which already holds one to each read relay.
     */
    private val lendable: Boolean = false,
    private val watchdogIdleMs: Long = WATCHDOG_IDLE_MS,
    private val watchdogReplyMs: Long = WATCHDOG_REPLY_MS,
) : RelayConnection {
    companion object {
        private const val TAG = "WebSocketClient"

        /** Every live client, so a blocklist change reaches sockets already open. */
        private val live: MutableSet<WebSocketClient> =
            java.util.Collections.synchronizedSet(java.util.Collections.newSetFromMap(java.util.WeakHashMap()))

        /** Open lendable sockets, keyed by [LookupSocketPool.relayKey]. */
        private val lenders = java.util.concurrent.ConcurrentHashMap<String, WebSocketClient>()

        /**
         * An open socket to [url] another feature may ride (the feed's), or
         * null. The borrower sends its own REQs on it and never disconnects it.
         */
        fun lend(url: String): WebSocketClient? =
            lenders[LookupSocketPool.relayKey(url)]?.takeIf { it.connectionState.value == ConnectionState.CONNECTED }

        /**
         * Call after the Never connect list changes: drops sockets to relays
         * now blocked and reconnects clients that were refused and no longer are.
         */
        fun blocklistChanged() {
            val clients = synchronized(live) { live.toList() }
            clients.forEach { it.applyBlocklist() }
        }
        private const val MAX_RECONNECT_ATTEMPTS = 10
        private const val INITIAL_BACKOFF_MS = 1000L
        private const val SLOW_RETRY_INTERVAL_MS = 120_000L // 2 minutes between slow retries
        /**
         * A connection counts as healthy, and the backoff starts over, only
         * once it has stayed up this long. Resetting on open made a relay that
         * accepts and then drops get redialled every second, forever.
         */
        internal const val STABLE_CONNECTION_MS = 60_000L

        /**
         * Liveness without OkHttp pings. OkHttp 4.12's ping timeout fails the
         * socket from its task thread and closes the okio streams while the
         * reader thread is still inside read(); okio buffers aren't thread-safe,
         * and the app died with NPE / "closed" / AIOOBE size=0 inside Buffer
         * (Moto, 4 crashes on 10-31). So pings are off, and a socket quiet for
         * this long gets a tiny REQ that every relay answers (EOSE or CLOSED).
         */
        internal const val WATCHDOG_IDLE_MS = 30_000L

        /**
         * No frame at all this long after the probe: the link is dead. The
         * watchdog calls [WebSocket.cancel], which only closes the raw socket,
         * so the reader fails on its own thread and nothing is closed under it.
         */
        internal const val WATCHDOG_REPLY_MS = 20_000L

        /** Subscription ids of watchdog probes; their replies never reach [messages]. */
        internal const val PROBE_PREFIX = "nv-wd-"

        /** A REQ that matches nothing: the relay just sends EOSE. */
        internal fun probe(subId: String): String =
            "[\"REQ\",\"$subId\",{\"ids\":[\"${"0".repeat(64)}\"],\"limit\":0}]"

        /** Whether [text] is a relay's answer to a watchdog probe. */
        internal fun isProbeReply(text: String): Boolean =
            text.startsWith("[\"EOSE\",\"$PROBE_PREFIX") || text.startsWith("[\"CLOSED\",\"$PROBE_PREFIX")

        /** Whether a socket that opened at [openedAtMs] and closed at [nowMs] earns a fresh backoff. */
        internal fun stayedUp(openedAtMs: Long, nowMs: Long): Boolean =
            openedAtMs > 0 && nowMs - openedAtMs >= STABLE_CONNECTION_MS

        /** Hosts [sharedLocalhostClient]'s hostname verifier accepts. */
        fun isLocalOrLanHost(url: String): Boolean {
            val host = runCatching { java.net.URI(url).host }.getOrNull()?.lowercase() ?: return false
            if (host == "127.0.0.1" || host == "localhost") return true
            // IP literals only: "10.example.com" is a public name.
            return Regex("^(192\\.168|10\\.\\d{1,3})\\.\\d{1,3}\\.\\d{1,3}$").matches(host)
        }

        /** Shared OkHttpClient for all normal (non-localhost) connections. */
        val sharedClient: OkHttpClient by lazy {
            OkHttpClient.Builder()
                .pingInterval(0, TimeUnit.SECONDS) // see WATCHDOG_IDLE_MS
                .connectTimeout(10, TimeUnit.SECONDS)
                .readTimeout(0, TimeUnit.SECONDS)
                .build()
        }

        /** Shared OkHttpClient for this device's relay and LAN relays; trust follows [LocalTls]. */
        val sharedLocalhostClient: OkHttpClient by lazy {
            OkHttpClient.Builder()
                .pingInterval(0, TimeUnit.SECONDS) // see WATCHDOG_IDLE_MS
                .connectTimeout(10, TimeUnit.SECONDS)
                .readTimeout(0, TimeUnit.SECONDS)
                .localTrust()
                .build()
        }
    }

    enum class ConnectionState {
        DISCONNECTED, CONNECTING, CONNECTED, RECONNECTING
    }

    private val _messages = MutableSharedFlow<String>(extraBufferCapacity = messageBuffer)
    override val messages: SharedFlow<String> = _messages.asSharedFlow()

    private val _connectionState = MutableStateFlow(ConnectionState.DISCONNECTED)
    override val connectionState: StateFlow<ConnectionState> = _connectionState.asStateFlow()

    /** Last WebSocket error message (for diagnostics). */
    @Volatile var lastError: String? = null
        private set

    private val socketLock = Any()
    private var webSocket: WebSocket? = null
    private var reconnectAttempts = 0
    @Volatile private var openedAtMs = 0L
    private var reconnectJob: Job? = null
    private var shouldReconnect = true
    @Volatile private var refusedByBlocklist = false
    @Volatile private var lastInboundMs = 0L

    /** Counts opened sockets, so a borrower can tell its socket was replaced. */
    private val _generation = MutableStateFlow(0)
    override val generation: StateFlow<Int> = _generation.asStateFlow()
    private var watchdogJob: Job? = null
    private var probes = 0

    init {
        live.add(this)
    }

    private fun applyBlocklist() {
        val blocked = RelayBlocklist.isBlocked(url)
        if (blocked) {
            val open = synchronized(socketLock) { webSocket.also { webSocket = null } } ?: return
            reconnectJob?.cancel()
            refusedByBlocklist = true
            open.cancel()
            _connectionState.value = ConnectionState.DISCONNECTED
        } else if (refusedByBlocklist && shouldReconnect) {
            refusedByBlocklist = false
            reconnectAttempts = 0
            doConnect()
        }
    }

    private val client: OkHttpClient
        // The trust-everything client only ever talks to this phone or the LAN,
        // even when a caller asked for it: the external-relay setting can point
        // a "local" socket at a public relay, which must get real TLS checks.
        get() = if (trustLocalhost && isLocalOrLanHost(url)) sharedLocalhostClient else sharedClient

    override fun connect() {
        shouldReconnect = true
        // Already open or dialling: a second socket would orphan the first
        // (it used to overwrite [webSocket] and leave the old one running).
        if (synchronized(socketLock) { webSocket != null }) return
        reconnectJob?.cancel()
        reconnectAttempts = 0
        doConnect()
    }

    override fun disconnect() {
        shouldReconnect = false
        refusedByBlocklist = false
        reconnectJob?.cancel()
        watchdogJob?.cancel()
        unlend()
        synchronized(socketLock) {
            val open = webSocket
            webSocket = null
            open?.close(1000, "Client disconnect")
        }
        _connectionState.value = ConnectionState.DISCONNECTED
    }

    override fun send(message: String): Boolean {
        synchronized(socketLock) {
            return webSocket?.send(message) ?: false
        }
    }

    /** Whether [ws] is still this client's socket; callbacks from an older one are ignored. */
    private fun isCurrent(ws: WebSocket): Boolean = synchronized(socketLock) { webSocket === ws }

    /** Drops [ws] if it is the current socket; false when it was an older one. */
    private fun release(ws: WebSocket): Boolean = synchronized(socketLock) {
        if (webSocket !== ws) return false
        webSocket = null
        unlend()
        true
    }

    private fun unlend() {
        if (lendable) lenders.remove(LookupSocketPool.relayKey(url), this)
    }

    private fun doConnect() {
        if (synchronized(socketLock) { webSocket != null }) return
        // Never connect: the owner blocked this relay. No retry; unblocking
        // reconnects it through [blocklistChanged].
        if (RelayBlocklist.isBlocked(url)) {
            if (BuildConfig.DEBUG) Log.d(TAG, "Blocked relay, not connecting: $url")
            refusedByBlocklist = true
            _connectionState.value = ConnectionState.DISCONNECTED
            return
        }
        // This host answered 429 or refused the upgrade lately: no dial until
        // its hold is over ([RateLimitBackoff]). A pooled socket just fails;
        // the pool cools down.
        val heldMs = RateLimitBackoff.remainingMs(url)
        if (heldMs > 0) {
            if (BuildConfig.DEBUG) Log.d(TAG, "Held host, waiting ${heldMs / 1000}s: $url")
            _connectionState.value = ConnectionState.DISCONNECTED
            reconnectJob?.cancel()
            if (shouldReconnect && autoReconnect) {
                reconnectJob = scope.launch(Dispatchers.IO) {
                    delay(heldMs)
                    doConnect()
                }
            }
            return
        }

        val request = try {
            Request.Builder()
                .url(url)
                .build()
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "Invalid WebSocket URL, skipping connect: $url")
            _connectionState.value = ConnectionState.DISCONNECTED
            return
        }

        synchronized(socketLock) {
            if (webSocket != null) return
            _connectionState.value = if (reconnectAttempts > 0) {
                ConnectionState.RECONNECTING
            } else {
                ConnectionState.CONNECTING
            }
            // Callbacks take socketLock in isCurrent/release, so none can run
            // before this assignment lands.
            webSocket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                if (!isCurrent(webSocket)) {
                    webSocket.cancel()
                    return
                }
                if (BuildConfig.DEBUG) Log.d(TAG, "Connected to $url")
                _generation.value++
                _connectionState.value = ConnectionState.CONNECTED
                openedAtMs = System.currentTimeMillis()
                if (lendable) lenders[LookupSocketPool.relayKey(url)] = this@WebSocketClient
                startWatchdog(webSocket)
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                if (!isCurrent(webSocket)) return
                lastInboundMs = System.currentTimeMillis()
                if (isProbeReply(text)) {
                    if (text.startsWith("[\"EOSE\"")) {
                        val subId = text.substringAfter(",\"").substringBefore('"')
                        webSocket.send("[\"CLOSE\",\"$subId\"]")
                    }
                    return
                }
                _messages.tryEmit(text)
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                if (BuildConfig.DEBUG) Log.d(TAG, "WebSocket closing: $code $reason")
                // Not the server's code: 1005 ("no status") and 1006 are
                // reserved, and echoing one makes OkHttp throw, turning a clean
                // close into a failure and a redial.
                webSocket.close(1000, null)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                if (BuildConfig.DEBUG) Log.d(TAG, "WebSocket closed: $code $reason")
                if (!release(webSocket)) return
                _connectionState.value = ConnectionState.DISCONNECTED
                scheduleReconnect()
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                Log.w(TAG, "WebSocket failure ($url): ${t.message}")
                if (!release(webSocket)) return
                lastError = t.message
                _connectionState.value = ConnectionState.DISCONNECTED
                val code = response?.code
                // 429 = rate-limited by the relay; retrying soon makes it worse
                // (damus bans and lists the IP). Every socket to this host
                // holds off for an hour or more; see [RateLimitBackoff].
                if (code == 429) {
                    val holdMs = RateLimitBackoff.limited(url)
                    Log.w(TAG, "429 from $url, holding the host for ${holdMs / 60_000} min")
                    reconnectAttempts = MAX_RECONNECT_ATTEMPTS
                } else if (code != null && code != 101) {
                    // Refused the upgrade (5xx, 52x, 404, a 200 page): every
                    // client waits out the hold instead of dialling on its own.
                    val holdMs = RateLimitBackoff.refused(url)
                    if (holdMs > 0) Log.w(TAG, "$code from $url, holding the host for ${holdMs / 1000}s")
                }
                scheduleReconnect()
            }
            })
        }
    }

    /**
     * Reset the reconnect counter so the next disconnect retries from attempt 1.
     * Call this after the app returns to the foreground or after a relay restart
     * to give connections a fresh set of retries.
     */
    fun resetReconnect() {
        reconnectAttempts = 0
    }

    /**
     * Probes [ws] whenever it has been quiet for [watchdogIdleMs] and cancels
     * it when the probe gets no frame back in [watchdogReplyMs]. Ends when
     * [ws] stops being this client's socket.
     */
    private fun startWatchdog(ws: WebSocket) {
        lastInboundMs = System.currentTimeMillis()
        watchdogJob?.cancel()
        watchdogJob = scope.launch(Dispatchers.IO) {
            while (isCurrent(ws)) {
                val quietMs = System.currentTimeMillis() - lastInboundMs
                if (quietMs < watchdogIdleMs) {
                    delay(watchdogIdleMs - quietMs)
                    continue
                }
                val sentAt = System.currentTimeMillis()
                if (!ws.send(probe(PROBE_PREFIX + (++probes)))) break
                delay(watchdogReplyMs)
                if (!isCurrent(ws)) break
                if (lastInboundMs < sentAt) {
                    Log.w(TAG, "No answer from $url in ${watchdogReplyMs / 1000}s, dropping the socket")
                    ws.cancel()
                    break
                }
            }
        }
    }

    private fun scheduleReconnect() {
        if (stayedUp(openedAtMs, System.currentTimeMillis())) {
            reconnectAttempts = 0
            RateLimitBackoff.recovered(url)
        }
        openedAtMs = 0L
        if (!shouldReconnect || !autoReconnect) return

        if (reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
            // Instead of giving up permanently, back off to a slow periodic retry
            // (every 2 minutes) so the connection can recover if the relay comes
            // back or the network changes.
            Log.w(TAG, "Max fast-reconnect attempts reached for $url, switching to slow retry")
            reconnectJob?.cancel()
            reconnectJob = scope.launch(Dispatchers.IO) {
                delay(SLOW_RETRY_INTERVAL_MS)
                reconnectAttempts = MAX_RECONNECT_ATTEMPTS // keep in slow mode
                if (BuildConfig.DEBUG) Log.d(TAG, "Slow-retry reconnecting to $url")
                doConnect()
            }
            return
        }

        val backoffMs = INITIAL_BACKOFF_MS * (1L shl reconnectAttempts.coerceAtMost(6))
        reconnectAttempts++

        reconnectJob?.cancel()
        reconnectJob = scope.launch(Dispatchers.IO) {
            delay(backoffMs)
            if (BuildConfig.DEBUG) Log.d(TAG, "Reconnecting to $url (attempt $reconnectAttempts)")
            doConnect()
        }
    }

}

/** What [LookupSocketPool] needs from a relay socket; [WebSocketClient] in the app, a fake in tests. */
interface RelayConnection {
    val messages: SharedFlow<String>
    val connectionState: StateFlow<WebSocketClient.ConnectionState>
    fun connect()
    fun send(message: String): Boolean
    fun disconnect()
    /** Another owner's socket ([LentConnection]): connect and disconnect are theirs. */
    val lent: Boolean get() = false
    /** Bumps on every new socket; null when the connection never changes under the pool. */
    val generation: StateFlow<Int>? get() = null
}

/**
 * [owner]'s open socket, ridden by [LookupSocketPool]: REQs and CLOSEs go out
 * on it, but it is never dialled or closed from here.
 */
class LentConnection(private val owner: RelayConnection) : RelayConnection {
    override val messages: SharedFlow<String> get() = owner.messages
    override val connectionState: StateFlow<WebSocketClient.ConnectionState> get() = owner.connectionState
    override fun connect() {}
    override fun send(message: String): Boolean = owner.send(message)
    override fun disconnect() {}
    override val lent: Boolean get() = true
    override val generation: StateFlow<Int>? get() = owner.generation
}
