package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenConfig
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.atomic.AtomicInteger

/**
 * A pasted link is fetched with [BlossomService.publicOnlyClient]: a server on
 * 127.0.0.1 (where this device's relay listens) never receives the request,
 * whatever name or redirect led there. The plain client still reaches it, so
 * the refusal comes from the guard, not from the test server.
 */
class BlossomPublicOnlyMirrorTest {
    private val requests = AtomicInteger()
    private val server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))

    init {
        Thread {
            while (!server.isClosed) {
                val socket = try { server.accept() } catch (_: Exception) { break }
                socket.use {
                    val line = it.getInputStream().bufferedReader().readLine() ?: return@use
                    if (line.startsWith("GET ")) requests.incrementAndGet()
                    it.getOutputStream().write("HTTP/1.1 500 No\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
                }
            }
        }.apply { isDaemon = true }.start()
    }

    @After fun stop() = server.close()

    private fun service(): BlossomService {
        val configStore = mockk<ConfigStore>(relaxed = true)
        every { configStore.config } returns MutableStateFlow(HavenConfig(ownerNpub = "npub1owner"))
        return BlossomService(configStore, mockk(relaxed = true), mockk(relaxed = true), mockk(relaxed = true), mockk(relaxed = true))
    }

    @Test fun aPastedLinkNeverReachesALoopbackServer() = runTest {
        val url = "http://127.0.0.1:${server.localPort}/a.jpg"
        val blossom = service()

        assertNull(blossom.mirrorUrlToLocal(url, publicOnly = true))
        assertEquals(0, requests.get())

        // Control: without the guard the same URL is requested.
        assertNull(blossom.mirrorUrlToLocal(url))
        assertEquals(1, requests.get())
    }
}
