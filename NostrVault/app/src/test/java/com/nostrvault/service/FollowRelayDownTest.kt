package com.nostrvault.service

import com.nostrvault.data.remote.RateLimitBackoff
import com.nostrvault.data.remote.WebSocketClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
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
import kotlin.concurrent.thread

/**
 * Which own relays the follow list's count leaves out, against real sockets ([askReplaceable] + [FollowListKnown]).
 * Only a relay whose connect failed at the socket, or one still held by the hold that failure started, is down (Tod
 * 2026-11-27, twin of web PR 2611): with 4 of 7 dead a second follow inside the hold must pass at 3 of 3 as the first
 * did. A connect timeout or a 429 hold still counts against (Tom/Tron, PR 2611 must-fix 1).
 */
class FollowRelayDownTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val alice = "a".repeat(64)
    private val servers = mutableListOf<MockWebServer>()
    private val raws = mutableListOf<ServerSocket>()
    private val held = java.util.Collections.synchronizedList(mutableListOf<java.net.Socket>())

    @After
    fun tearDown() {
        servers.forEach { runCatching { it.shutdown() } }
        raws.forEach { runCatching { it.close() } }
        held.forEach { runCatching { it.close() } }
        RateLimitBackoff.clearForTest()
    }

    /** [n] relays on 127.0.0.1 (never held: a local host) that answer every REQ with EOSE. */
    private fun live(n: Int): List<String> {
        val server = MockWebServer().also { servers += it }
        repeat(n * 4) {
            server.enqueue(MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
                override fun onMessage(webSocket: WebSocket, text: String) {
                    if (text.startsWith("[\"REQ\"")) webSocket.send("[\"EOSE\",\"${text.substringAfter(",\"").substringBefore('"')}\"]")
                }
                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(1000, null) }
            }))
        }
        server.start(InetAddress.getByName("127.0.0.1"), 0)
        return (1..n).map { "ws://127.0.0.1:${server.port}/live$it" }
    }

    /** [n] relays on ::1 (held like a public host) that refuse the upgrade with 503: dead. */
    private fun dead(n: Int): Pair<MockWebServer, List<String>> {
        val server = MockWebServer().also { servers += it }
        repeat(n * 4) { server.enqueue(MockResponse().setResponseCode(503)) }
        server.start(InetAddress.getByName("::1"), 0)
        return server to (1..n).map { "ws://[::1]:${server.port}/dead$it" }
    }

    /** [n] relays that take the TCP connection and never answer the upgrade: the connect times out. */
    private fun silent(n: Int): List<String> {
        val raw = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1")).also { raws += it }
        // Keep every accepted socket open (and referenced): it reads nothing and answers nothing.
        thread(isDaemon = true) { while (!raw.isClosed) runCatching { held += raw.accept() } }
        return (1..n).map { "ws://127.0.0.1:${raw.localPort}/silent$it" }
    }

    /** Asks every relay at once, as lookupNewestReplaceable does; a list is found. */
    private fun ask(urls: List<String>, timeoutMs: Long = 3_000): NostrService.ReplaceableLookup = runBlocking(Dispatchers.IO) {
        val asks = urls.map { url ->
            async { url to askReplaceable(WebSocketClient(url, this, autoReconnect = false), json, 3, alice, null, timeoutMs) {} }
        }.awaitAll()
        val answeredBy = asks.filter { it.second.answered }.map { it.first }.toSet()
        NostrService.ReplaceableLookup(
            NostrEvent(id = "f".repeat(64), pubkey = alice, createdAt = 100, kind = 3, tags = emptyList(), content = "", sig = ""),
            asked = urls.size, answered = answeredBy.size, answeredBy = answeredBy,
            reachedBy = asks.filter { it.second.reached }.map { it.first }.toSet(),
        )
    }

    @Test fun `with 4 of 7 dead a second follow inside the hold passes at 3 of 3, as the first`() {
        val (deadServer, down) = dead(4)
        val own = live(3) + down
        val first = ask(own)
        assertEquals(3, first.answered)
        assertEquals(own.take(3).toSet(), first.reachedBy)
        assertNull(FollowListKnown.unknownWhy(own, first, found = true))
        // The refusals held the host: the second ask doesn't dial it, and still leaves it out.
        assertTrue(RateLimitBackoff.remainingMs(down[0]) > 0)
        val dials = deadServer.requestCount
        val second = ask(own)
        assertEquals(dials, deadServer.requestCount)
        assertEquals(own.take(3).toSet(), second.reachedBy)
        assertNull(FollowListKnown.unknownWhy(own, second, found = true))
    }

    @Test fun `a connect that times out still counts against`() {
        // Old rule (2612): a relay that never connected dropped out, so 2 of 2 passed.
        val own = live(2) + silent(2)
        val lookup = ask(own, timeoutMs = 1_500)
        assertEquals(2, lookup.answered)
        assertEquals(own.toSet(), lookup.reachedBy)
        assertEquals(ListMerge.NOT_ANSWERED, FollowListKnown.unknownWhy(own, lookup, found = true))
    }

    @Test fun `a relay held for a 429 still counts against`() {
        val (_, busy) = dead(2)
        busy.forEach { RateLimitBackoff.limited(it) }
        val own = live(2) + busy
        val lookup = ask(own)
        assertEquals(own.toSet(), lookup.reachedBy)
        assertEquals(ListMerge.NOT_ANSWERED, FollowListKnown.unknownWhy(own, lookup, found = true))
    }

    @Test fun `a refused connection drops out`() {
        val closed = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { it.localPort }
        val own = live(2) + listOf("ws://127.0.0.1:$closed/a", "ws://127.0.0.1:$closed/b")
        val lookup = ask(own)
        assertEquals(own.take(2).toSet(), lookup.reachedBy)
        assertNull(FollowListKnown.unknownWhy(own, lookup, found = true))
    }

    @Test fun `no list yet needs every own relay, dead ones too`() {
        // Old rule (2612): "none" from the 2 that connected was enough.
        val (_, down) = dead(1)
        val own = live(2) + down
        val lookup = ask(own).copy(event = null)
        assertEquals(ListMerge.NOT_ANSWERED, FollowListKnown.unknownWhy(own, lookup, found = false))
    }
}
