package com.nostrvault.service

import com.nostrvault.data.remote.RelayConnection
import com.nostrvault.data.remote.WebSocketClient.ConnectionState
import com.nostrvault.relay.HavenConfig
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * /private and /chat answer COUNT only after the owner's NIP-42 AUTH. The
 * COUNTs wait for `OK true` on that AUTH, and anything short of a real
 * number for every COUNT is "couldn't count" (null), never 0.
 */
class StatsCountAuthTest {
    private class FakeConnection : RelayConnection {
        override val messages = MutableSharedFlow<String>(extraBufferCapacity = 64)
        override val connectionState = MutableStateFlow(ConnectionState.DISCONNECTED)
        val sent = mutableListOf<String>()
        var disconnected = false

        override fun connect() { connectionState.value = ConnectionState.CONNECTED }
        override fun send(message: String): Boolean { sent += message; return true }
        override fun disconnect() { disconnected = true }

        fun relay(msg: String) { check(messages.tryEmit(msg)) }
        val countSubIds: List<String>
            get() = sent.mapNotNull { Regex("^\\[\"COUNT\",\"([^\"]+)\"").find(it)?.groupValues?.get(1) }
        fun answerCounts(count: String = "3") = countSubIds.forEach { relay("""["COUNT","$it",{"count":$count}]""") }
    }

    private val tag = "ws://127.0.0.1:3355/private"
    private val authId = "a".repeat(64)
    private val signed = authId to """{"id":"$authId","kind":22242}"""
    private val scope = CoroutineScope(Dispatchers.Unconfined)

    private fun count(
        conn: FakeConnection,
        authRelayTag: String? = tag,
        timeoutMs: Long = 2_000,
        signAuth: suspend (String, String) -> Pair<String, String>? = { _, _ -> signed },
    ): Deferred<Pair<Map<Int, Int>, Map<Int, Int>>?> = scope.async {
        StatsService.countOver(conn, scope, listOf(1), null, authRelayTag, signAuth, timeoutMs)
    }

    @Test fun `counts wait for OK true on the owner's AUTH`() = runBlocking {
        val conn = FakeConnection()
        var signedFor: Pair<String, String>? = null
        val result = count(conn) { relayTag, challenge -> signedFor = relayTag to challenge; signed }
        assertTrue("no COUNT before AUTH", conn.countSubIds.isEmpty())

        conn.relay("""["AUTH","chal"]""")
        assertEquals(tag to "chal", signedFor)
        assertEquals("""["AUTH",${signed.second}]""", conn.sent.single())
        assertTrue("no COUNT before OK", conn.countSubIds.isEmpty())

        conn.relay("""["OK","$authId",true,""]""")
        assertEquals(2, conn.countSubIds.size)
        conn.answerCounts()
        assertEquals(mapOf(StatsService.TOTAL_KEY to 3, 1 to 3), result.await()!!.first)
        assertTrue(conn.disconnected)
    }

    @Test fun `a refused AUTH is couldn't count`() = runBlocking {
        val conn = FakeConnection()
        val result = count(conn)
        conn.relay("""["AUTH","chal"]""")
        conn.relay("""["OK","$authId",false,"restricted: not the owner"]""")
        assertNull(result.await())
        assertTrue(conn.countSubIds.isEmpty())
    }

    @Test fun `an OK for another event does not release the counts`() = runBlocking {
        val conn = FakeConnection()
        val result = count(conn, timeoutMs = 100)
        conn.relay("""["AUTH","chal"]""")
        conn.relay("""["OK","${"b".repeat(64)}",true,""]""")
        assertTrue(conn.countSubIds.isEmpty())
        assertNull(result.await())
    }

    @Test fun `a NOTICE is couldn't count`() = runBlocking {
        val conn = FakeConnection()
        val result = count(conn)
        conn.relay("""["AUTH","chal"]""")
        conn.relay("""["OK","$authId",true,""]""")
        conn.relay("""["NOTICE","auth-required: COUNT"]""")
        assertNull(result.await())
    }

    /** Watch-only or a signer that isn't connected: no AUTH, no COUNT. */
    @Test fun `an owner who can't sign is couldn't count`() = runBlocking {
        val conn = FakeConnection()
        val result = count(conn) { _, _ -> null }
        conn.relay("""["AUTH","chal"]""")
        assertNull(result.await())
        assertTrue(conn.sent.isEmpty())
    }

    @Test fun `no challenge in time is couldn't count`() = runBlocking {
        assertNull(count(FakeConnection(), timeoutMs = 100).await())
    }

    @Test fun `a COUNT with no number is couldn't count, not 0`() = runBlocking {
        val conn = FakeConnection()
        val result = count(conn, authRelayTag = null)
        conn.answerCounts(count = "null")
        assertNull(result.await())
    }

    @Test fun `routes without AUTH count straight away`() = runBlocking {
        val conn = FakeConnection()
        val result = count(conn, authRelayTag = null)
        assertEquals(2, conn.countSubIds.size)
        conn.answerCounts("0")
        assertEquals(mapOf(StatsService.TOTAL_KEY to 0, 1 to 0), result.await()!!.first)
    }

    @Test fun `only private and chat need the owner's AUTH`() {
        val config = HavenConfig(ownerNpub = "npub1test")
        assertEquals(tag, StatsService.authRelayTag(config, tag))
        assertEquals("ws://127.0.0.1:3355/chat", StatsService.authRelayTag(config, "ws://127.0.0.1:3355/chat"))
        assertNull(StatsService.authRelayTag(config, "ws://127.0.0.1:3355"))
        assertNull(StatsService.authRelayTag(config, "ws://127.0.0.1:3355/inbox"))
    }

    @Test fun `an external relay is never asked for AUTH`() {
        val config = HavenConfig(ownerNpub = "npub1test", useExternalRelay = true, externalRelayURL = "wss://relay.example.com")
        StatsService.countEndpoints(config).forEach { assertNull(StatsService.authRelayTag(config, it)) }
    }
}
