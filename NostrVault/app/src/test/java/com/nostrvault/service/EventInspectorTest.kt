package com.nostrvault.service

import com.nostrvault.data.remote.RelayConnection
import com.nostrvault.data.remote.WebSocketClient.ConnectionState
import com.nostrvault.relay.HavenConfig
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
 * The Event Info lookup and re-broadcast against fake relays: each relay's
 * answer (has it / doesn't / refused / dropped / silent), forged copies,
 * and that "Sent" waits for the relay's OK.
 */
class EventInspectorTest {

    private class FakeConnection(val url: String) : RelayConnection {
        override val messages = MutableSharedFlow<String>(extraBufferCapacity = 64)
        val state = MutableStateFlow(ConnectionState.DISCONNECTED)
        override val connectionState = state
        val sent = mutableListOf<String>()
        var disconnected = false

        override fun connect() { state.value = ConnectionState.CONNECTING }
        override fun send(message: String): Boolean { sent += message; return true }
        override fun disconnect() { disconnected = true }

        fun open() { state.value = ConnectionState.CONNECTED }
        fun drop() { state.value = ConnectionState.DISCONNECTED }
        fun relay(msg: String) { check(messages.tryEmit(msg)) }
        val subId: String get() = Regex("\"REQ\",\"([^\"]+)\"").find(sent.first())!!.groupValues[1]
    }

    private val id = "a".repeat(64)
    private val good = """{"id":"$id","pubkey":"${"b".repeat(64)}","created_at":1,"kind":1,"tags":[],"content":"hi","sig":"${"c".repeat(128)}"}"""
    private val forged = good.replace("\"hi\"", "\"bye\"")

    private val config = HavenConfig(
        ownerNpub = "npub1owner",
        relayURL = "ws://127.0.0.1:3355",
        feedRelays = listOf("wss://feed.example"),
        blastrRelays = listOf("wss://blast.example", "wss://feed.example"),
    )

    private val opened = mutableMapOf<String, FakeConnection>()

    private fun TestScope.inspector(cached: String? = null) = EventInspector(
        eventId = id,
        config = config,
        scope = backgroundScope,
        cachedEventJson = cached,
        connectionFactory = { url -> FakeConnection(url).also { opened[url] = it } },
        verify = { it == good },
    )

    @Test
    fun `relays are listed once each, this device first`() = runTest {
        val insp = inspector()
        insp.start()
        assertEquals(
            listOf("ws://127.0.0.1:3355", "ws://127.0.0.1:3355/inbox", "wss://feed.example", "wss://blast.example"),
            insp.relays.value,
        )
        assertEquals("This device", insp.label("ws://127.0.0.1:3355"))
        assertEquals("This device (inbox)", insp.label("ws://127.0.0.1:3355/inbox"))
        assertEquals("feed.example", insp.label("wss://feed.example"))
    }

    @Test
    fun `each relay's answer lands in presence and the verified copy is adopted`() = runTest {
        val insp = inspector()
        insp.start()
        runCurrent()
        opened.values.forEach { it.open() }
        runCurrent()

        val local = opened.getValue("ws://127.0.0.1:3355")
        val inbox = opened.getValue("ws://127.0.0.1:3355/inbox")
        val feed = opened.getValue("wss://feed.example")
        local.relay("""["EVENT","${local.subId}",$good]""")
        inbox.relay("""["EOSE","${inbox.subId}"]""")
        feed.relay("""["CLOSED","${feed.subId}","auth-required: sign in"]""")
        runCurrent()
        // blast.example stays silent.
        advanceTimeBy(7_000)
        runCurrent()

        val p = insp.presence.value
        assertEquals(RelayPresence.Found, p["ws://127.0.0.1:3355"])
        assertEquals(RelayPresence.NotFound, p["ws://127.0.0.1:3355/inbox"])
        assertEquals(RelayPresence.Failed("auth-required: sign in"), p["wss://feed.example"])
        assertEquals(RelayPresence.Failed("timeout"), p["wss://blast.example"])
        assertEquals(good, insp.event.value)
        assertEquals(SignatureCheck.VALID, insp.signature.value)
        assertFalse(insp.isFetching.value)
        assertTrue(opened.values.all { it.disconnected })
    }

    @Test
    fun `a forged copy does not count and is not adopted`() = runTest {
        val insp = inspector()
        insp.start()
        runCurrent()
        val feed = opened.getValue("wss://feed.example")
        feed.open()
        runCurrent()
        feed.relay("""["EVENT","${feed.subId}",$forged]""")
        runCurrent()

        assertEquals(
            RelayPresence.Failed("sent a copy that fails the signature check"),
            insp.presence.value["wss://feed.example"],
        )
        assertNull(insp.event.value)
        assertEquals(SignatureCheck.UNKNOWN, insp.signature.value)
    }

    @Test
    fun `a socket that drops is a connection failure, not a timeout`() = runTest {
        val insp = inspector()
        insp.start()
        runCurrent()
        opened.getValue("wss://feed.example").drop()
        runCurrent()
        assertEquals(RelayPresence.Failed("connection failed"), insp.presence.value["wss://feed.example"])
    }

    @Test
    fun `a cached copy that fails verification shows as invalid`() = runTest {
        val insp = inspector(cached = forged)
        assertEquals(SignatureCheck.INVALID, insp.signature.value)
    }

    @Test
    fun `broadcast waits for each relay's OK and reports its reason`() = runTest {
        val insp = inspector(cached = good)
        val results = mutableMapOf<String, Pair<Boolean, String>>()
        insp.broadcast(listOf("wss://ok.example", "wss://no.example", "wss://silent.example")) { relay, ok, msg ->
            results[relay] = ok to msg
        }
        runCurrent()
        opened.values.forEach { it.open() }
        runCurrent()
        assertTrue(opened.getValue("wss://ok.example").sent.single().startsWith("[\"EVENT\","))
        assertTrue(results.isEmpty()) // nothing counts as sent before the relay answers

        opened.getValue("wss://ok.example").relay("""["OK","$id",true,""]""")
        opened.getValue("wss://no.example").relay("""["OK","$id",false,"blocked: not on the allow list"]""")
        runCurrent()
        advanceTimeBy(11_000)
        runCurrent()

        assertEquals(true to "", results["wss://ok.example"])
        assertEquals(false to "blocked: not on the allow list", results["wss://no.example"])
        assertEquals(false to "timeout", results["wss://silent.example"])
        assertEquals(RelayPresence.Found, insp.presence.value["wss://ok.example"])
        assertTrue("wss://ok.example" in insp.relays.value)
        assertFalse("wss://no.example" in insp.relays.value)
    }

    @Test
    fun `plain ws is only allowed to this device`() {
        assertTrue(EventInspector.isUsableRelay("wss://relay.example"))
        assertTrue(EventInspector.isUsableRelay("ws://127.0.0.1:3355/inbox"))
        assertFalse(EventInspector.isUsableRelay("ws://relay.example"))
        assertFalse(EventInspector.isUsableRelay("https://relay.example"))
    }
}
