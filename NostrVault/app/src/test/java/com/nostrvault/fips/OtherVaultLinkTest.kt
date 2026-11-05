package com.nostrvault.fips

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URI
import kotlin.concurrent.thread

/**
 * The other vault's lasting address: the relay keeps what it still has to read by URL, and the mesh ingress port
 * changes with every engine start, so the copy is given a kept loopback port that forwards to the current ingress.
 * Real loopback sockets; an "ingress" here is a local server that answers with its own name.
 */
class OtherVaultLinkTest {
    private class MemStore : OtherVaultLink.Store {
        override var npub: String? = null
        override var port = 0
        override var until = 0L
        override var token: String? = null
    }

    private val servers = mutableListOf<ServerSocket>()
    private var ingress: String? = null
    private var dials = 0
    private val store = MemStore()
    private val link = OtherVaultLink(store) { dials++; ingress }

    @After fun tearDown() {
        link.close()
        servers.forEach { it.close() }
    }

    /** Request lines the stand-in ingresses received. */
    private val received = java.util.Collections.synchronizedList(mutableListOf<String>())

    /** A stand-in ingress: reads the request line, answers one line per connection. */
    private fun fakeIngress(reply: String): ServerSocket {
        val s = ServerSocket(0, 50, InetAddress.getLoopbackAddress()).also { servers += it }
        thread(isDaemon = true) {
            while (!s.isClosed) {
                val c = runCatching { s.accept() }.getOrNull() ?: break
                runCatching { c.getInputStream().bufferedReader().readLine()?.let { received += it } }
                runCatching { c.getOutputStream().write("$reply\n".toByteArray()) }
                c.close()
            }
        }
        ingress = "http://127.0.0.1:${s.localPort}"
        return s
    }

    /** One request to [url]'s port for [path] (the address's own path, token and all, unless given). */
    private fun read(url: String, path: String = URI(url).path): String? = runCatching {
        Socket("127.0.0.1", URI(url).port).use {
            it.soTimeout = 5_000
            it.getOutputStream().write("GET $path HTTP/1.1\r\n".toByteArray())
            it.getInputStream().bufferedReader().readLine()
        }
    }.getOrNull()

    @Test fun `the address forwards to the other vault and is kept with its npub`() {
        fakeIngress("vault A")
        val url = link.open("npub1a", now = 1_000)!!
        assertEquals("vault A", read(url))
        assertEquals("npub1a", store.npub)
        assertEquals(1_000 + OtherVaultCopy.KEEP_LINK_MS, store.until)
    }

    @Test fun `after an engine restart the same address reaches the new ingress`() {
        val old = fakeIngress("first engine")
        val url = link.open("npub1a", now = 0)!!
        assertEquals("first engine", read(url))
        old.close()
        fakeIngress("second engine")
        // An app restart: a fresh link object reads the store and comes back on the same port.
        val token = store.token
        link.close().also { store.npub = "npub1a"; store.port = URI(url).port; store.until = OtherVaultCopy.KEEP_LINK_MS; store.token = token }
        val again = OtherVaultLink(store) { ingress }
        again.restore(now = 1)
        assertEquals(url, again.url())
        assertEquals("second engine", read(url))
        again.close()
    }

    @Test fun `a refused ingress is dialed again within the same connection`() {
        val old = fakeIngress("first engine")
        val url = link.open("npub1a", now = 0)!!
        assertEquals("first engine", read(url))
        old.close()
        fakeIngress("second engine")
        assertEquals("second engine", read(url))
        assertEquals(2, dials)
    }

    @Test fun `an expired address is let go on the next engine start`() {
        fakeIngress("vault A")
        val url = link.open("npub1a", now = 0)!!
        link.restore(now = OtherVaultCopy.KEEP_LINK_MS)
        assertNull(link.url())
        assertNull(store.npub)
        assertNull(read(url))
    }

    @Test fun `another device's npub gets its own address`() {
        fakeIngress("vault A")
        val a = link.open("npub1a", now = 0)
        val b = link.open("npub1b", now = 0)
        assertNotNull(b)
        assertNotEquals(null, a)
        assertEquals("npub1b", store.npub)
    }

    @Test fun `nothing kept, nothing restored`() {
        link.restore(now = 0)
        assertNull(link.url())
        assertEquals(0, dials)
    }

    @Test fun `the address carries a secret and the vault never sees it`() {
        fakeIngress("vault A")
        val url = link.open("npub1a", now = 0)!!
        val token = store.token!!
        assertEquals(64, token.length)
        assertEquals("ws://127.0.0.1:${URI(url).port}/$token", url)
        assertEquals("vault A", read(url))
        assertEquals("vault A", read(url, "/$token/list/ab?x=1"))
        assertEquals(listOf("GET / HTTP/1.1", "GET /list/ab?x=1 HTTP/1.1"), received.toList())
    }

    @Test fun `another app on the phone without the secret gets nothing and nothing is dialed`() {
        fakeIngress("vault A")
        val url = link.open("npub1a", now = 0)!!
        val token = store.token!!
        assertNull(read(url, "/"))
        assertNull(read(url, "/list/ab"))
        assertNull(read(url, "/${token.dropLast(1)}"))
        assertNull(read(url, "/${token}x"))
        assertEquals(0, dials)
        assertTrue(received.isEmpty())
    }

    @Test fun `a kept address from before the secret is let go, not reopened`() {
        store.npub = "npub1a"; store.port = 0; store.until = OtherVaultCopy.KEEP_LINK_MS; store.token = null
        link.restore(now = 0)
        assertNull(link.url())
        assertNull(store.npub)
    }

    @Test fun `a new link gets a new secret`() {
        fakeIngress("vault A")
        link.open("npub1a", now = 0)
        val first = store.token
        link.close()
        link.open("npub1a", now = 0)
        assertNotEquals(first, store.token)
    }

    @Test fun `the path check`() {
        val t = "ab12"
        assertEquals("GET / HTTP/1.1\r\n", withoutToken("GET /ab12 HTTP/1.1\r\n", t))
        assertEquals("GET /x?y HTTP/1.1\r\n", withoutToken("GET /ab12/x?y HTTP/1.1\r\n", t))
        assertEquals("GET /?y HTTP/1.1\r\n", withoutToken("GET /ab12?y HTTP/1.1\r\n", t))
        assertNull(withoutToken("GET /ab123 HTTP/1.1\r\n", t))
        assertNull(withoutToken("GET /ab1 HTTP/1.1\r\n", t))
        assertNull(withoutToken("GET / HTTP/1.1\r\n", t))
        assertNull(withoutToken("garbage", t))
        assertNull(withoutToken("GET /ab12 HTTP/1.1\r\n", ""))
    }
}
