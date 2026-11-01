package com.nostrvault.data.remote

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress
import java.net.ServerSocket
import java.security.MessageDigest
import java.util.Base64
import kotlin.concurrent.thread

/**
 * [WebSocketClient] against real sockets on this machine: one socket per
 * client, a clean close stays clean, and a refusing relay is held for every
 * client, not redialled by each one.
 */
class WebSocketClientSocketTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val server = MockWebServer()
    private val clients = mutableListOf<WebSocketClient>()

    @After
    fun tearDown() {
        clients.forEach { it.disconnect() }
        scope.cancel()
        server.shutdown()
        RateLimitBackoff.clearForTest()
    }

    private fun client(
        url: String,
        autoReconnect: Boolean = false,
        idleMs: Long = WebSocketClient.WATCHDOG_IDLE_MS,
        replyMs: Long = WebSocketClient.WATCHDOG_REPLY_MS,
    ) = WebSocketClient(url, scope, autoReconnect = autoReconnect, watchdogIdleMs = idleMs, watchdogReplyMs = replyMs)
        .also { clients += it }

    private fun waitFor(what: String, timeoutMs: Long = 5_000, check: () -> Boolean) {
        val end = System.currentTimeMillis() + timeoutMs
        while (!check()) {
            if (System.currentTimeMillis() > end) throw AssertionError("timed out waiting for $what")
            Thread.sleep(20)
        }
    }

    /** Answers the upgrade and echoes the client's close, like a relay. */
    private fun upgrade() = MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(1000, null)
        }
    })

    private fun wsUrl(host: String = "127.0.0.1") =
        "ws://$host:${server.port}/"

    @Test
    fun `connect on an open or dialling client opens no second socket`() {
        repeat(3) { server.enqueue(upgrade()) }
        server.start(InetAddress.getByName("127.0.0.1"), 0)
        val c = client(wsUrl())
        c.connect()
        c.connect() // while dialling
        waitFor("connected") { c.connectionState.value == WebSocketClient.ConnectionState.CONNECTED }
        c.connect() // while open
        c.connect()
        Thread.sleep(300)
        assertEquals(1, server.requestCount)
    }

    @Test
    fun `the old socket's close does not knock out or redial the new one`() {
        repeat(4) { server.enqueue(upgrade()) }
        server.start(InetAddress.getByName("127.0.0.1"), 0)
        val c = client(wsUrl(), autoReconnect = true)
        c.connect()
        waitFor("first open") { c.connectionState.value == WebSocketClient.ConnectionState.CONNECTED }
        c.disconnect()
        c.connect()
        waitFor("second open") { server.requestCount == 2 &&
            c.connectionState.value == WebSocketClient.ConnectionState.CONNECTED }
        // The first socket's onClosed lands now; it used to mark the client
        // DISCONNECTED and schedule a redial 1 s later (a third socket).
        Thread.sleep(2_000)
        assertEquals(WebSocketClient.ConnectionState.CONNECTED, c.connectionState.value)
        assertEquals(2, server.requestCount)
    }

    @Test
    fun `a refusing relay is held for every client`() {
        server.enqueue(MockResponse().setResponseCode(503))
        server.enqueue(MockResponse().setResponseCode(503))
        // ::1 is not on the local/LAN list, so it is held like a public relay.
        server.start(InetAddress.getByName("::1"), 0)
        val url = wsUrl("[::1]")
        val a = client(url)
        a.connect()
        waitFor("refusal") { a.lastError != null }
        val held = RateLimitBackoff.remainingMs(url)
        assertTrue("held ${held}ms", held in 1..30_000)

        val b = client(url)
        b.connect()
        Thread.sleep(300)
        assertEquals(WebSocketClient.ConnectionState.DISCONNECTED, b.connectionState.value)
        assertEquals(1, server.requestCount)
    }

    @Test
    fun `a refusing local relay path is not held`() {
        server.enqueue(MockResponse().setResponseCode(404))
        server.start(InetAddress.getByName("127.0.0.1"), 0)
        val c = client(wsUrl())
        c.connect()
        waitFor("refusal") { c.lastError != null }
        assertEquals(0L, RateLimitBackoff.remainingMs(wsUrl()))
    }

    /**
     * A close frame with no status reads as code 1005, which may not be sent.
     * Echoing it threw inside OkHttp and turned the close into a failure
     * ("Code 1005 is reserved", 12 on the Moto in 7 min).
     */
    @Test
    fun `a close with no status code stays a clean close`() {
        val raw = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        val serverThread = thread(isDaemon = true) {
            raw.accept().use { s ->
                val input = s.getInputStream().bufferedReader()
                var key = ""
                while (true) {
                    val line = input.readLine() ?: return@thread
                    if (line.isEmpty()) break
                    if (line.startsWith("Sec-WebSocket-Key:", ignoreCase = true)) key = line.substringAfter(':').trim()
                }
                val accept = Base64.getEncoder().encodeToString(
                    MessageDigest.getInstance("SHA-1")
                        .digest((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").toByteArray()),
                )
                val out = s.getOutputStream()
                out.write(
                    ("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
                        "Sec-WebSocket-Accept: $accept\r\n\r\n").toByteArray(),
                )
                out.flush()
                Thread.sleep(300)
                out.write(byteArrayOf(0x88.toByte(), 0x00)) // close, no status
                out.flush()
                Thread.sleep(1_000) // let the client answer before the socket goes
            }
        }
        val c = client("ws://127.0.0.1:${raw.localPort}/")
        c.connect()
        waitFor("open") { c.connectionState.value == WebSocketClient.ConnectionState.CONNECTED }
        waitFor("closed") { c.connectionState.value == WebSocketClient.ConnectionState.DISCONNECTED }
        Thread.sleep(200)
        assertNull("close turned into a failure: ${c.lastError}", c.lastError)
        serverThread.join(3_000)
        raw.close()
    }

    @Test
    fun `OkHttp pings are off on both shared clients`() {
        assertEquals(0, WebSocketClient.sharedClient.pingIntervalMillis)
        assertEquals(0, WebSocketClient.sharedLocalhostClient.pingIntervalMillis)
    }

    /** Answers every REQ with EOSE, like a relay; records what the client sent. */
    private fun relay(sent: MutableList<String>) = MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
        override fun onMessage(webSocket: WebSocket, text: String) {
            synchronized(sent) { sent += text }
            if (text.startsWith("[\"REQ\"")) {
                val subId = text.substringAfter(",\"").substringBefore('"')
                webSocket.send("[\"EOSE\",\"$subId\"]")
            }
        }
        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(1000, null)
        }
    })

    @Test
    fun `a quiet socket that answers the probe stays up and the reply stays inside`() {
        val sent = mutableListOf<String>()
        server.enqueue(relay(sent))
        server.start(InetAddress.getByName("127.0.0.1"), 0)
        val c = client(wsUrl(), idleMs = 200, replyMs = 300)
        val seen = java.util.Collections.synchronizedList(mutableListOf<String>())
        val collector = scope.launch { c.messages.collect { seen += it } }
        c.connect()
        waitFor("open") { c.connectionState.value == WebSocketClient.ConnectionState.CONNECTED }
        Thread.sleep(1_500)
        assertEquals(WebSocketClient.ConnectionState.CONNECTED, c.connectionState.value)
        assertEquals(1, server.requestCount)
        val probes = synchronized(sent) { sent.count { it.startsWith("[\"REQ\",\"${WebSocketClient.PROBE_PREFIX}") } }
        assertTrue("probes sent: $probes", probes >= 2)
        assertTrue("probe CLOSE sent", synchronized(sent) { sent.any { it.startsWith("[\"CLOSE\",\"${WebSocketClient.PROBE_PREFIX}") } })
        assertTrue("probe replies leaked: $seen", seen.isEmpty())
        collector.cancel()
    }

    @Test
    fun `a socket that never answers is dropped and redialled`() {
        // Upgrades, then ignores every message: a link that has gone quiet.
        repeat(2) { server.enqueue(upgrade()) }
        server.start(InetAddress.getByName("127.0.0.1"), 0)
        val c = client(wsUrl(), autoReconnect = true, idleMs = 200, replyMs = 200)
        c.connect()
        waitFor("open") { c.connectionState.value == WebSocketClient.ConnectionState.CONNECTED }
        waitFor("dropped and redialled", timeoutMs = 4_000) { server.requestCount == 2 }
    }

    @Test
    fun `only an open lendable socket is lent, and not after it closes`() {
        repeat(2) { server.enqueue(upgrade()) }
        server.start(InetAddress.getByName("127.0.0.1"), 0)
        val url = wsUrl()
        val plain = client(url)
        plain.connect()
        waitFor("plain open") { plain.connectionState.value == WebSocketClient.ConnectionState.CONNECTED }
        assertNull("not lendable", WebSocketClient.lend(url))
        plain.disconnect()

        val feed = WebSocketClient(url, scope, lendable = true).also { clients += it }
        assertNull("not open yet", WebSocketClient.lend(url))
        feed.connect()
        waitFor("feed open") { feed.connectionState.value == WebSocketClient.ConnectionState.CONNECTED }
        assertTrue(WebSocketClient.lend(url.uppercase().replace("WS://", "ws://")) === feed)
        feed.disconnect()
        assertNull("closed", WebSocketClient.lend(url))
    }
}
