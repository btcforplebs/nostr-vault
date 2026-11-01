package com.nostrvault.data.remote

import com.nostrvault.data.remote.LookupSocketPool.Outcome
import com.nostrvault.data.remote.WebSocketClient.ConnectionState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * One connection per relay: the pool rides the feed's open socket (lent) when
 * there is one, posts wait for OK on a shared socket, and live subscriptions
 * survive a dropped socket.
 */
class LookupSocketPoolSharingTest {

    private class FakeConnection(val url: String) : RelayConnection {
        override val messages = MutableSharedFlow<String>(extraBufferCapacity = 64)
        val state = MutableStateFlow(ConnectionState.DISCONNECTED)
        override val connectionState = state
        val gen = MutableStateFlow(0)
        override val generation = gen
        val sent = mutableListOf<String>()
        var disconnected = false

        override fun connect() { state.value = ConnectionState.CONNECTING }
        override fun send(message: String): Boolean { sent += message; return true }
        override fun disconnect() {
            disconnected = true
            state.value = ConnectionState.DISCONNECTED
        }

        fun open() { state.value = ConnectionState.CONNECTED; gen.value++ }
        fun relay(msg: String) { check(messages.tryEmit(msg)) }
    }

    private val opened = mutableListOf<FakeConnection>()
    /** The feed's open sockets, by URL. */
    private val feed = mutableMapOf<String, FakeConnection>()

    private fun TestScope.pool(scope: CoroutineScope = backgroundScope, maxSockets: Int = 32) = LookupSocketPool(
        scope = scope,
        connectionFactory = { url -> FakeConnection(url).also { opened += it } },
        clock = { testScheduler.currentTime },
        idleMs = 20_000,
        cooldownMs = 120_000,
        maxSockets = maxSockets,
        lender = { url -> feed[url]?.takeIf { it.state.value == ConnectionState.CONNECTED }?.let(::LentConnection) },
    )

    private val filter = """{"ids":["aa"]}"""
    private val relay = "wss://relay.example.com"

    private fun feedSocket(url: String = relay) = FakeConnection(url).also { it.open(); feed[url] = it }

    @Test
    fun `a lookup rides the feed's open socket under a lent id and dials nothing`() = runTest {
        val owner = feedSocket()
        val pool = pool()
        val seen = mutableListOf<String>()
        val lookup = async { pool.query(relay, "ring-1", listOf(filter), 8_000) { seen += it } }
        runCurrent()
        assertTrue("no socket of its own", opened.isEmpty())
        assertEquals(listOf("""["REQ","nv-l-ring-1",$filter]"""), owner.sent)

        owner.relay("""["EVENT","nv-l-ring-1",{"id":"x"}]""")
        owner.relay("""["EOSE","nv-l-ring-1"]""")
        assertEquals(Outcome.EOSE, lookup.await())
        // The caller reads its own id.
        assertEquals(listOf("""["EVENT","ring-1",{"id":"x"}]""", """["EOSE","ring-1"]"""), seen)
        assertEquals("""["CLOSE","nv-l-ring-1"]""", owner.sent.last())
        assertEquals(0, pool.openSocketCount)

        advanceTimeBy(30_000)
        assertFalse("the feed's socket is never closed by the pool", owner.disconnected)
    }

    @Test
    fun `the feed's own traffic on the lent socket never reaches the lookup`() = runTest {
        val owner = feedSocket()
        val pool = pool()
        val seen = mutableListOf<String>()
        val lookup = async { pool.query(relay, "q", listOf(filter), 8_000) { seen += it } }
        runCurrent()
        owner.relay("""["EVENT","feed-following",{"id":"f"}]""")
        owner.relay("""["EVENT","q",{"id":"same id, no prefix"}]""")
        owner.relay("""["EOSE","nv-l-q"]""")
        lookup.await()
        assertEquals(listOf("""["EOSE","q"]"""), seen)
    }

    @Test
    fun `the feed skips the frames of lookups riding its sockets`() {
        assertTrue(LookupSocketPool.isLentSubscription("EVENT", "nv-l-ring-1"))
        assertTrue(LookupSocketPool.isLentSubscription("EOSE", "nv-l-x"))
        assertFalse(LookupSocketPool.isLentSubscription("EVENT", "feed-following"))
        assertFalse(LookupSocketPool.isLentSubscription("OK", "nv-l-x"))
    }

    @Test
    fun `a lent socket that drops fails its lookups without a cooldown`() = runTest {
        val owner = feedSocket()
        val pool = pool()
        val lookup = async { pool.query(relay, "s1", listOf(filter), 8_000) {} }
        runCurrent()
        owner.state.value = ConnectionState.RECONNECTING // the feed is redialling
        assertEquals(Outcome.FAILED, lookup.await())
        assertFalse("the feed redials it; the pool doesn't hold it", pool.isCoolingDown(relay))
        assertFalse(owner.disconnected)
    }

    @Test
    fun `a lent socket the owner replaced fails its lookups`() = runTest {
        val owner = feedSocket()
        val pool = pool()
        val lookup = async { pool.query(relay, "s1", listOf(filter), 8_000) {} }
        runCurrent()
        owner.gen.value++ // dropped and reopened between two looks at its state
        assertEquals(Outcome.FAILED, lookup.await())
    }

    @Test
    fun `with no feed socket the pool dials its own`() = runTest {
        val pool = pool()
        val lookup = async { pool.query(relay, "s1", listOf(filter), 8_000) {} }
        runCurrent()
        assertEquals(1, opened.size)
        opened.single().open()
        runCurrent()
        assertEquals(listOf("""["REQ","s1",$filter]"""), opened.single().sent)
        opened.single().relay("""["EOSE","s1"]""")
        assertEquals(Outcome.EOSE, lookup.await())
    }

    @Test
    fun `a post waits for its OK on the feed's socket`() = runTest {
        val owner = feedSocket()
        val pool = pool()
        val post = async { pool.publish(relay, "e1", """{"id":"e1"}""", 10_000) }
        runCurrent()
        assertTrue(opened.isEmpty())
        assertEquals(listOf("""["EVENT",{"id":"e1"}]"""), owner.sent)
        owner.relay("""["OK","e1",true,""]""")
        assertEquals(true to "", post.await())
        assertEquals("no CLOSE for a post", 1, owner.sent.size)
    }

    @Test
    fun `a refused post reports the relay's message`() = runTest {
        feedSocket()
        val pool = pool()
        val post = async { pool.publish(relay, "e1", """{"id":"e1"}""", 10_000) }
        runCurrent()
        feed.getValue(relay).relay("""["OK","e1",false,"blocked: spam"]""")
        assertEquals(false to "blocked: spam", post.await())
    }

    @Test
    fun `a post with no answer is not accepted`() = runTest {
        feedSocket()
        val pool = pool()
        val post = async { pool.publish(relay, "e1", """{"id":"e1"}""", 10_000) }
        advanceTimeBy(10_001)
        assertEquals(false to "it didn't answer", post.await())
    }

    @Test
    fun `the same post sent twice at once goes out once and both get the answer`() = runTest {
        val owner = feedSocket()
        val pool = pool()
        val first = async { pool.publish(relay, "e1", """{"id":"e1"}""", 10_000) }
        runCurrent()
        val second = async { pool.publish(relay, "e1", """{"id":"e1"}""", 10_000) }
        runCurrent()
        assertEquals(1, owner.sent.size)
        owner.relay("""["OK","e1",true,"dup ok"]""")
        assertEquals(true to "dup ok", first.await())
        assertEquals(true to "dup ok", second.await())
    }

    @Test
    fun `a post is never skipped for a full pool`() = runTest {
        val pool = pool(maxSockets = 1)
        val busy = async { pool.query("wss://other.example.com", "s1", listOf(filter), 8_000) {} }
        runCurrent()
        opened.single().open()
        runCurrent()
        val post = async { pool.publish(relay, "e1", """{"id":"e1"}""", 10_000) }
        runCurrent()
        assertEquals(2, opened.size)
        opened[1].open()
        runCurrent()
        opened[1].relay("""["OK","e1",true,""]""")
        assertEquals(true to "", post.await())
        busy.cancel()
    }

    @Test
    fun `a live subscription stays open past EOSE and is CLOSEd when cancelled`() = runTest {
        val owner = feedSocket()
        val pool = pool()
        val seen = mutableListOf<String>()
        val live = launch { pool.stream(relay, "live-1", listOf(filter)) { seen += it } }
        runCurrent()
        owner.relay("""["EOSE","nv-l-live-1"]""")
        advanceTimeBy(10_000)
        assertEquals("still the first REQ, not CLOSEd at EOSE", 1, owner.sent.size)
        owner.relay("""["EVENT","nv-l-live-1",{"id":"new"}]""")
        runCurrent()
        assertEquals(2, seen.size)
        live.cancel()
        runCurrent()
        assertEquals("""["CLOSE","nv-l-live-1"]""", owner.sent.last())
    }

    @Test
    fun `a live subscription asks again on a new socket after a drop`() = runTest {
        val owner = feedSocket()
        val pool = pool()
        val live = launch { pool.stream(relay, "live-1", listOf(filter), retryMs = 5_000) {} }
        runCurrent()
        owner.state.value = ConnectionState.RECONNECTING
        runCurrent()
        // The feed is back with a new socket.
        owner.open()
        advanceTimeBy(5_001)
        runCurrent()
        assertEquals(2, owner.sent.count { it.startsWith("""["REQ","nv-l-live-1"""") })
        live.cancel()
    }

    @Test
    fun `a live subscription ends when the relay CLOSEs it`() = runTest {
        val owner = feedSocket()
        val pool = pool()
        val live = async { pool.stream(relay, "live-1", listOf(filter)) {} }
        runCurrent()
        owner.relay("""["CLOSED","nv-l-live-1","auth-required"]""")
        live.await()
        advanceTimeBy(60_000)
        assertEquals(1, owner.sent.count { it.startsWith("[\"REQ\"") })
    }
}
