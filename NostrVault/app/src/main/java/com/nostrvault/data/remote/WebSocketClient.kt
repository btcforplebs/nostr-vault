package com.nostrvault.data.remote

import android.util.Log
import com.nostrvault.BuildConfig
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
import java.security.cert.X509Certificate
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

/**
 * Port of WebSocketClient.swift -- OkHttp WebSocket with auto-reconnect.
 *
 * Features:
 * - 25-second ping interval (matches iOS keepalive)
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
) : RelayConnection {
    companion object {
        private const val TAG = "WebSocketClient"

        /** Every live client, so a blocklist change reaches sockets already open. */
        private val live: MutableSet<WebSocketClient> =
            java.util.Collections.synchronizedSet(java.util.Collections.newSetFromMap(java.util.WeakHashMap()))

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
                .pingInterval(25, TimeUnit.SECONDS)
                .connectTimeout(10, TimeUnit.SECONDS)
                .readTimeout(0, TimeUnit.SECONDS)
                .build()
        }

        /** Shared OkHttpClient for localhost / LAN connections with self-signed cert trust. */
        val sharedLocalhostClient: OkHttpClient by lazy {
            val trustManager = object : X509TrustManager {
                override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) {}
                override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {}
                override fun getAcceptedIssuers(): Array<X509Certificate> = arrayOf()
            }
            val sslContext = SSLContext.getInstance("TLS")
            sslContext.init(null, arrayOf<TrustManager>(trustManager), null)
            OkHttpClient.Builder()
                .pingInterval(25, TimeUnit.SECONDS)
                .connectTimeout(10, TimeUnit.SECONDS)
                .readTimeout(0, TimeUnit.SECONDS)
                .sslSocketFactory(sslContext.socketFactory, trustManager)
                .hostnameVerifier { hostname, _ ->
                    hostname == "127.0.0.1" || hostname == "localhost" ||
                        hostname.startsWith("192.168.") || hostname.startsWith("10.")
                }
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
    private var reconnectJob: Job? = null
    private var shouldReconnect = true
    @Volatile private var refusedByBlocklist = false

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
        reconnectAttempts = 0
        doConnect()
    }

    override fun disconnect() {
        shouldReconnect = false
        refusedByBlocklist = false
        reconnectJob?.cancel()
        synchronized(socketLock) {
            webSocket?.close(1000, "Client disconnect")
            webSocket = null
        }
        _connectionState.value = ConnectionState.DISCONNECTED
    }

    override fun send(message: String): Boolean {
        synchronized(socketLock) {
            return webSocket?.send(message) ?: false
        }
    }

    private fun doConnect() {
        if (_connectionState.value == ConnectionState.CONNECTING) return
        // Never connect: the owner blocked this relay. No retry; unblocking
        // reconnects it through [blocklistChanged].
        if (RelayBlocklist.isBlocked(url)) {
            if (BuildConfig.DEBUG) Log.d(TAG, "Blocked relay, not connecting: $url")
            refusedByBlocklist = true
            _connectionState.value = ConnectionState.DISCONNECTED
            return
        }

        _connectionState.value = if (reconnectAttempts > 0) {
            ConnectionState.RECONNECTING
        } else {
            ConnectionState.CONNECTING
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
            webSocket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                if (BuildConfig.DEBUG) Log.d(TAG, "Connected to $url")
                _connectionState.value = ConnectionState.CONNECTED
                reconnectAttempts = 0
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                _messages.tryEmit(text)
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                if (BuildConfig.DEBUG) Log.d(TAG, "WebSocket closing: $code $reason")
                webSocket.close(code, reason)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                if (BuildConfig.DEBUG) Log.d(TAG, "WebSocket closed: $code $reason")
                _connectionState.value = ConnectionState.DISCONNECTED
                scheduleReconnect()
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                Log.w(TAG, "WebSocket failure ($url): ${t.message}")
                lastError = t.message
                _connectionState.value = ConnectionState.DISCONNECTED
                // 429 = rate-limited by the relay; retrying immediately makes it worse.
                // Switch directly to slow-retry mode so we back off for 2 minutes.
                if (response?.code == 429) {
                    reconnectAttempts = MAX_RECONNECT_ATTEMPTS
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

    private fun scheduleReconnect() {
        if (!shouldReconnect || !autoReconnect) return

        if (reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
            // Instead of giving up permanently, back off to a slow periodic retry
            // (every 2 minutes) so the connection can recover if the relay comes
            // back or the network changes.
            Log.w(TAG, "Max fast-reconnect attempts reached for $url, switching to slow retry")
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
}
