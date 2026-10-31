package com.nostrvault.service

import com.nostrvault.data.remote.RelayConnection
import com.nostrvault.data.remote.WebSocketClient.ConnectionState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Vault tab counts /private and /chat after the owner's AUTH. The socket
 * stays open once logged in, so a second visit counts on it with no new AUTH.
 */
class StatsCountReuseTest {
    private class FakeConnection : RelayConnection {
        override val messages = MutableSharedFlow<String>(extraBufferCapacity = 64)
        override val connectionState = MutableStateFlow(ConnectionState.DISCONNECTED)
        val sent = mutableListOf<String>()
        var connects = 0
        var disconnected = false

        override fun connect() { connects++; connectionState.value = ConnectionState.CONNECTED }
        override fun send(message: String): Boolean { sent += message; return true }
        override fun disconnect() { disconnected = true }

        fun relay(msg: String) { check(messages.tryEmit(msg)) }
        val countSubIds: List<String>
            get() = sent.mapNotNull { Regex("^\\[\"COUNT\",\"([^\"]+)\"").find(it)?.groupValues?.get(1) }
        fun answerCounts() = countSubIds.forEach { relay("""["COUNT","$it",{"count":3}]""") }
    }

    private val tag = "ws://127.0.0.1:3355/private"
    private val authId = "a".repeat(64)
    private val scope = CoroutineScope(Dispatchers.Unconfined)
    private var signs = 0
    private val signAuth: suspend (String, String) -> Pair<String, String>? = { _, _ ->
        signs++; authId to """{"id":"$authId","kind":22242}"""
    }

    private fun count(conn: FakeConnection, alreadyAuthed: Boolean) = scope.async {
        StatsService.countOver(conn, scope, listOf(1), null, tag, signAuth, 2_000, alreadyAuthed, keepOpen = true)
    }

    @Test fun `a second visit counts on the open socket without signing`() = runBlocking {
        val conn = FakeConnection()
        val first = count(conn, alreadyAuthed = false)
        conn.relay("""["AUTH","chal"]""")
        conn.relay("""["OK","$authId",true,""]""")
        conn.answerCounts()
        assertEquals(3, first.await()!!.first[1])
        assertFalse("kept open", conn.disconnected)
        assertEquals(1, signs)

        conn.sent.clear()
        val second = count(conn, alreadyAuthed = true)
        assertEquals("COUNTs go at once", 2, conn.countSubIds.size)
        conn.answerCounts()
        assertEquals(3, second.await()!!.first[1])
        assertEquals("no new AUTH", 1, signs)
        assertEquals("no new connect", 1, conn.connects)
        assertFalse(conn.disconnected)
    }

    @Test fun `a failed count on a kept socket closes it`() = runBlocking {
        val conn = FakeConnection()
        conn.connect()
        val result = count(conn, alreadyAuthed = true)
        conn.relay("""["NOTICE","restart"]""")
        assertNull(result.await())
        assertTrue(conn.disconnected)
        assertEquals(0, signs)
    }
}
