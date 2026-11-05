package com.nostrvault.service

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.net.InetAddress
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger

/**
 * The signer storm (Tal, iOS #1739): every vault query and publish opened its own socket and logged in again, so a
 * bunker or Amber signer was asked for a NIP-42 AUTH each time. Against a vault that asks for AUTH on every
 * connection, a session's requests to one path now share one logged-in socket: one sign, until the socket drops.
 */
class VaultSocketAuthCountTest {
    private val server = MockWebServer()
    private val json = Json { ignoreUnknownKeys = true }

    /** AUTH events the vault received, connections it opened, and the sockets (to drop them). */
    private val auths = AtomicInteger()
    private val connections = AtomicInteger()
    private val sockets = CopyOnWriteArrayList<WebSocket>()
    private val signs = AtomicInteger()

    @Before
    fun setUp() {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest) = MockResponse().withWebSocketUpgrade(FakeVault())
        }
        server.start(InetAddress.getByName("127.0.0.1"), 0)
        VaultSocket.closeAllForTest()
    }

    @After
    fun tearDown() {
        VaultSocket.closeAllForTest()
        server.shutdown()
    }

    private val url get() = "ws://127.0.0.1:${server.port}/lists"

    /** A NIP-42 vault: challenges on connect, refuses before AUTH, answers after. */
    private inner class FakeVault : WebSocketListener() {
        @Volatile private var authed = false

        override fun onOpen(webSocket: WebSocket, response: Response) {
            connections.incrementAndGet()
            sockets += webSocket
            webSocket.send("[\"AUTH\",\"challenge-${connections.get()}\"]")
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            val arr = json.parseToJsonElement(text).jsonArray
            when (arr[0].jsonPrimitive.content) {
                "AUTH" -> {
                    auths.incrementAndGet()
                    authed = true
                    val id = arr[1].jsonObject["id"]!!.jsonPrimitive.content
                    webSocket.send("[\"OK\",\"$id\",true,\"\"]")
                }
                "REQ" -> {
                    val sub = arr[1].jsonPrimitive.content
                    webSocket.send(if (authed) "[\"EOSE\",\"$sub\"]" else "[\"CLOSED\",\"$sub\",\"auth-required: log in first\"]")
                }
                "EVENT" -> {
                    val id = (arr[1] as kotlinx.serialization.json.JsonObject)["id"]!!.jsonPrimitive.content
                    webSocket.send(if (authed) "[\"OK\",\"$id\",true,\"\"]" else "[\"OK\",\"$id\",false,\"auth-required: log in first\"]")
                }
                "CLOSE" -> Unit
            }
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(1000, null)
        }
    }

    private val signAuth: suspend (String) -> NostrEvent? = { challenge ->
        signs.incrementAndGet()
        NostrEvent("auth-${signs.get()}", "ab".repeat(32), 1, 22242, listOf(listOf("challenge", challenge)), "", "00".repeat(64))
    }

    private fun note(n: Int) = NostrEvent("note-$n", "ab".repeat(32), 1, 3, emptyList(), "", "00".repeat(64))

    @Test
    fun `five queries and three publishes to one path log in once`() = runBlocking {
        repeat(5) { assertTrue("query $it answered", VaultSocket.query(url, "{\"kinds\":[3]}", signAuth) != null) }
        repeat(3) { assertTrue("publish $it accepted", VaultSocket.publish(url, note(it), signAuth)) }

        assertEquals("AUTH signs (was one per request: 8)", 1, signs.get())
        assertEquals(1, auths.get())
        assertEquals("sockets opened (was 8)", 1, connections.get())
    }

    @Test
    fun `a dropped socket logs in again once`() = runBlocking {
        repeat(3) { VaultSocket.query(url, "{\"kinds\":[3]}", signAuth) }
        sockets.forEach { it.close(1001, "going away") }
        Thread.sleep(300)
        repeat(3) { assertTrue(VaultSocket.query(url, "{\"kinds\":[3]}", signAuth) != null) }

        assertEquals("one login per connection", 2, signs.get())
        assertEquals(2, connections.get())
    }
}
