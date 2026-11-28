package com.nostrvault.data.remote

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * In the background a dropped socket to a public relay is not redialled until
 * the app is back on screen; the DM live socket keeps redialling. Hosts under
 * .invalid never resolve, so each dial fails at once without a network.
 */
class WebSocketClientBackgroundTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val clients = mutableListOf<WebSocketClient>()

    @After
    fun tearDown() {
        clients.forEach { it.disconnect() }
        scope.cancel()
        RateLimitBackoff.clearForTest()
        AppOnScreen.setForTest(true)
    }

    private fun client(url: String, keepUp: Boolean = false) =
        WebSocketClient(url, scope, autoReconnect = true, keepUpInBackground = keepUp).also { clients += it }

    private fun waitFor(what: String, timeoutMs: Long = 10_000, check: () -> Boolean) {
        val end = System.currentTimeMillis() + timeoutMs
        while (!check()) {
            if (System.currentTimeMillis() > end) throw AssertionError("timed out waiting for $what")
            Thread.sleep(20)
        }
    }

    @Test
    fun `a failed dial holds the host for every client`() {
        val a = client("wss://held.nv-test.invalid")
        a.connect()
        waitFor("a hold") { RateLimitBackoff.remainingMs("wss://held.nv-test.invalid/other") > 0 }
    }

    @Test
    fun `in the background a public relay parks and redials on return`() {
        AppOnScreen.setForTest(false)
        val c = client("wss://park.nv-test.invalid")
        c.connect()
        waitFor("parked") { c.parkedForBackground }
        AppOnScreen.set(true)
        assertFalse(c.parkedForBackground)
    }

    @Test
    fun `the DM live socket never parks`() {
        AppOnScreen.setForTest(false)
        val c = client("wss://dm.nv-test.invalid", keepUp = true)
        c.connect()
        waitFor("a failed dial") { c.lastError != null }
        Thread.sleep(200)
        assertFalse(c.parkedForBackground)
    }

    @Test
    fun `a local relay keeps redialling in the background`() {
        AppOnScreen.setForTest(false)
        val port = java.net.ServerSocket(0, 1, java.net.InetAddress.getByName("127.0.0.1")).use { it.localPort }
        val c = client("ws://127.0.0.1:$port")
        c.connect()
        waitFor("a failed dial") { c.lastError != null }
        Thread.sleep(200)
        assertFalse(c.parkedForBackground)
        assertTrue(RateLimitBackoff.remainingMs("ws://127.0.0.1:$port") == 0L)
    }
}
