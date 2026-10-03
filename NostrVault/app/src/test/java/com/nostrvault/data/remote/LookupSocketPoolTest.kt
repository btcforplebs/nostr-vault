package com.nostrvault.data.remote

import com.nostrvault.data.remote.LookupSocketPool.Outcome
import com.nostrvault.data.remote.WebSocketClient.ConnectionState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The lookup pool against fake sockets: one socket per relay reused across
 * lookups, REQs held through the handshake, per-subscription EOSE and
 * timeout, idle close, and the two-minute back-off after a refusal.
 */
class LookupSocketPoolTest {

    private class FakeConnection(val url: String) : RelayConnection {
        override val messages = MutableSharedFlow<String>(extraBufferCapacity = 64)
        val state = MutableStateFlow(ConnectionState.DISCONNECTED)
        override val connectionState = state
        val sent = mutableListOf<String>()
        var disconnected = false

        override fun connect() { state.value = ConnectionState.CONNECTING }
        override fun send(message: String): Boolean { sent += message; return true }
        override fun disconnect() {
            disconnected = true
            state.value = ConnectionState.DISCONNECTED
        }

        fun open() { state.value = ConnectionState.CONNECTED }
        /** What OkHttp reports for a refused handshake (a 429 included). */
        fun refuse() { state.value = ConnectionState.DISCONNECTED }
        fun relay(msg: String) { check(messages.tryEmit(msg)) }
    }

    private val opened = mutableListOf<FakeConnection>()

    private fun TestScope.pool(scope: CoroutineScope = backgroundScope, maxSockets: Int = 32) = LookupSocketPool(
        scope = scope,
        connectionFactory = { url -> FakeConnection(url).also { opened += it } },
        clock = { testScheduler.currentTime },
        idleMs = 20_000,
        cooldownMs = 120_000,
        maxSockets = maxSockets,
    )

    private val filter = """{"ids":["aa"]}"""
    private val relay = "wss://relay.example.com"

    @Test
    fun `lookups to one relay share one socket`() = runTest {
        val pool = pool()
        val first = async { pool.query(relay, "s1", listOf(filter), 8_000) {} }
        runCurrent()
        opened.single().open()
        runCurrent()
        opened.single().relay("""["EOSE","s1"]""")
        assertEquals(Outcome.EOSE, first.await())

        // Trailing slash and case normalise to the same relay.
        val second = async { pool.query("WSS://relay.example.com/", "s2", listOf(filter), 8_000) {} }
        runCurrent()
        opened.single().relay("""["EOSE","s2"]""")
        assertEquals(Outcome.EOSE, second.await())

        assertEquals(1, opened.size)
        val reqs = opened.single().sent.filter { it.startsWith("[\"REQ\"") }
        assertEquals(listOf("""["REQ","s1",$filter]""", """["REQ","s2",$filter]"""), reqs)
    }

    @Test
    fun `REQs wait for the handshake`() = runTest {
        val pool = pool()
        val lookup = async { pool.query(relay, "s1", listOf(filter), 8_000) {} }
        runCurrent()
        val socket = opened.single()
        assertTrue("nothing goes out before the socket opens", socket.sent.isEmpty())
        socket.open()
        runCurrent()
        assertEquals(listOf("""["REQ","s1",$filter]"""), socket.sent)
        socket.relay("""["EOSE","s1"]""")
        lookup.await()
    }

    @Test
    fun `concurrent lookups are routed by subscription id`() = runTest {
        val pool = pool()
        val gotA = mutableListOf<String>()
        val gotB = mutableListOf<String>()
        val a = async { pool.query(relay, "a", listOf(filter), 8_000) { gotA += it } }
        val b = async { pool.query(relay, "b", listOf(filter), 8_000) { gotB += it } }
        runCurrent()
        val socket = opened.single()
        socket.open()
        runCurrent()
        socket.relay("""["EVENT","a",{"id":"1"}]""")
        socket.relay("""["EVENT","b",{"id":"2"}]""")
        socket.relay("""["EOSE","a"]""")
        runCurrent()
        assertTrue(a.isCompleted)
        assertFalse("b's EOSE has not arrived", b.isCompleted)
        socket.relay("""["CLOSED","b","rate-limited"]""")
        assertEquals(Outcome.EOSE, a.await())
        assertEquals(Outcome.CLOSED, b.await())
        assertEquals(listOf("""["EVENT","a",{"id":"1"}]""", """["EOSE","a"]"""), gotA)
        assertEquals(listOf("""["EVENT","b",{"id":"2"}]""", """["CLOSED","b","rate-limited"]"""), gotB)
        // a ended at EOSE, so we CLOSE it; the relay already closed b.
        assertTrue("""["CLOSE","a"]""" in socket.sent)
        assertFalse("""["CLOSE","b"]""" in socket.sent)
    }

    @Test
    fun `a lookup with no EOSE times out and is CLOSEd`() = runTest {
        val pool = pool()
        val lookup = async { pool.query(relay, "s1", listOf(filter), 8_000) {} }
        runCurrent()
        opened.single().open()
        advanceTimeBy(8_001)
        assertEquals(Outcome.TIMEOUT, lookup.await())
        assertEquals("""["CLOSE","s1"]""", opened.single().sent.last())
        assertFalse(opened.single().disconnected)
    }

    @Test
    fun `socket closes after going quiet, not before`() = runTest {
        val pool = pool()
        val first = async { pool.query(relay, "s1", listOf(filter), 8_000) {} }
        runCurrent()
        val socket = opened.single()
        socket.open()
        runCurrent()
        socket.relay("""["EOSE","s1"]""")
        first.await()

        // Another lookup inside the quiet period reuses the socket and
        // restarts the clock.
        advanceTimeBy(15_000)
        assertFalse(socket.disconnected)
        val second = async { pool.query(relay, "s2", listOf(filter), 8_000) {} }
        runCurrent()
        socket.relay("""["EOSE","s2"]""")
        second.await()
        advanceTimeBy(15_000)
        assertFalse("quiet period restarted at the last lookup", socket.disconnected)
        assertEquals(1, pool.openSocketCount)

        advanceTimeBy(5_001)
        assertTrue(socket.disconnected)
        assertEquals(0, pool.openSocketCount)

        // The next lookup dials a fresh socket.
        val third = async { pool.query(relay, "s3", listOf(filter), 8_000) {} }
        runCurrent()
        assertEquals(2, opened.size)
        opened[1].open()
        runCurrent()
        opened[1].relay("""["EOSE","s3"]""")
        third.await()
    }

    @Test
    fun `a refused relay is left alone for two minutes`() = runTest {
        val pool = pool()
        val lookup = async { pool.query(relay, "s1", listOf(filter), 8_000) {} }
        runCurrent()
        opened.single().refuse()
        assertEquals(Outcome.FAILED, lookup.await())
        assertTrue(pool.isCoolingDown(relay))

        advanceTimeBy(60_000)
        assertEquals(Outcome.SKIPPED, pool.query(relay, "s2", listOf(filter), 8_000) {})
        assertEquals("no redial during the back-off", 1, opened.size)

        advanceTimeBy(60_001)
        assertFalse(pool.isCoolingDown(relay))
        val retry = async { pool.query(relay, "s3", listOf(filter), 8_000) {} }
        runCurrent()
        assertEquals(2, opened.size)
        opened[1].open()
        runCurrent()
        opened[1].relay("""["EOSE","s3"]""")
        assertEquals(Outcome.EOSE, retry.await())
    }

    @Test
    fun `a dropped socket fails its open lookups and backs off`() = runTest {
        val pool = pool()
        val lookup = async { pool.query(relay, "s1", listOf(filter), 8_000) {} }
        runCurrent()
        opened.single().open()
        runCurrent()
        opened.single().refuse()
        assertEquals(Outcome.FAILED, lookup.await())
        assertTrue(pool.isCoolingDown(relay))
        assertEquals(0, pool.openSocketCount)
    }

    @Test
    fun `other relays are unaffected by one relay's back-off`() = runTest {
        val pool = pool()
        val bad = async { pool.query(relay, "s1", listOf(filter), 8_000) {} }
        runCurrent()
        opened.single().refuse()
        bad.await()
        val good = async { pool.query("wss://other.example.com", "s2", listOf(filter), 8_000) {} }
        runCurrent()
        assertEquals(2, opened.size)
        opened[1].open()
        runCurrent()
        opened[1].relay("""["EOSE","s2"]""")
        assertEquals(Outcome.EOSE, good.await())
    }

    @Test
    fun `a full pool evicts an idle socket, and skips when none is idle`() = runTest {
        val pool = pool(maxSockets = 1)
        val busy = async { pool.query(relay, "s1", listOf(filter), 8_000) {} }
        runCurrent()
        opened.single().open()
        runCurrent()
        assertEquals(Outcome.SKIPPED, pool.query("wss://other.example.com", "s2", listOf(filter), 8_000) {})
        opened.single().relay("""["EOSE","s1"]""")
        busy.await()

        val next = async { pool.query("wss://other.example.com", "s3", listOf(filter), 8_000) {} }
        runCurrent()
        assertTrue("idle socket made room", opened[0].disconnected)
        assertEquals(2, opened.size)
        opened[1].open()
        runCurrent()
        opened[1].relay("""["EOSE","s3"]""")
        next.await()
    }

    @Test
    fun `route reads type and subscription id`() {
        assertEquals("EVENT" to "sub-1", LookupSocketPool.route("""["EVENT","sub-1",{"id":"x"}]"""))
        assertEquals("EOSE" to "q", LookupSocketPool.route("""[ "EOSE" , "q" ]"""))
        assertEquals("CLOSED" to "a\"b", LookupSocketPool.route("""["CLOSED","a\"b","why"]"""))
        assertNull(LookupSocketPool.route("""["NOTICE"]"""))
        assertNull(LookupSocketPool.route("not json"))
    }
}
