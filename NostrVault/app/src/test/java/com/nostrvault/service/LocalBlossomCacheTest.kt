package com.nostrvault.service

import com.nostrvault.relay.BlossomUploadProbe
import com.nostrvault.relay.BlossomUploadSupport
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LocalBlossomCacheTest {
    private val hash = "b1674191a88ec5cdd733e4240a81803105dc412d6c6708d53ab94fc248f4f553"

    @Test
    fun `blob URLs go through the cache with the origin as hint`() {
        assertEquals(
            "http://127.0.0.1:24242/$hash.jpg?xs=https%3A%2F%2Fblossom.primal.net",
            LocalBlossomCache.cacheUrlFor("https://blossom.primal.net/$hash.jpg"),
        )
        assertEquals(
            "http://127.0.0.1:24242/$hash?xs=https%3A%2F%2Fcdn.example%3A8443%2Fmedia",
            LocalBlossomCache.cacheUrlFor("https://cdn.example:8443/media/$hash"),
        )
    }

    @Test
    fun `non-blob and on-phone URLs are left alone`() {
        assertNull(LocalBlossomCache.cacheUrlFor("https://example.com/cat.jpg"))
        assertNull(LocalBlossomCache.cacheUrlFor("https://example.com/${hash.take(63)}.jpg"))
        assertNull(LocalBlossomCache.cacheUrlFor("http://127.0.0.1:3355/$hash"))
        assertNull(LocalBlossomCache.cacheUrlFor("http://localhost:24242/$hash"))
        assertNull(LocalBlossomCache.cacheUrlFor("ftp://example.com/$hash"))
    }

    @Test
    fun `upload probe tells a Blossom server from a read-only cache`() {
        // khatru: missing auth -> 401 with X-Reason
        assertEquals(BlossomUploadSupport.ACCEPTS_UPLOADS, BlossomUploadProbe.classify(401, true))
        assertEquals(BlossomUploadSupport.ACCEPTS_UPLOADS, BlossomUploadProbe.classify(200, false))
        assertEquals(BlossomUploadSupport.ACCEPTS_UPLOADS, BlossomUploadProbe.classify(400, true))
        // Morganite: HEAD /upload -> 400, no X-Reason
        assertEquals(BlossomUploadSupport.READ_ONLY, BlossomUploadProbe.classify(400, false))
        assertEquals(BlossomUploadSupport.READ_ONLY, BlossomUploadProbe.classify(404, false))
        assertEquals(BlossomUploadSupport.READ_ONLY, BlossomUploadProbe.classify(405, false))
        // Nostr Vault for Mac's TLS port asked over plain http
        assertEquals(BlossomUploadSupport.NEEDS_HTTPS, BlossomUploadProbe.classify(400, false, http10 = true))
    }

    /** A one-thread HTTP/1.1 server: [respond] maps (method, path+query) to (status, body). */
    private class TinyServer(port: Int, val respond: (String, String) -> Pair<Int, String>) : AutoCloseable {
        val socket = java.net.ServerSocket(port, 50, java.net.InetAddress.getByName("127.0.0.1"))
        val port: Int get() = socket.localPort
        private val thread = Thread {
            while (!socket.isClosed) {
                val conn = runCatching { socket.accept() }.getOrNull() ?: break
                conn.use { c ->
                    val reader = c.getInputStream().bufferedReader()
                    val requestLine = reader.readLine() ?: return@use
                    while (reader.readLine()?.isNotEmpty() == true) { /* headers */ }
                    val (method, target) = requestLine.split(" ").let { it[0] to it[1] }
                    val (status, body) = respond(method, target)
                    val bytes = if (method == "HEAD") ByteArray(0) else body.toByteArray()
                    val out = c.getOutputStream()
                    out.write(("HTTP/1.1 $status X\r\nContent-Length: ${body.toByteArray().size}\r\n" +
                        "Connection: close\r\n\r\n").toByteArray())
                    out.write(bytes)
                    out.flush()
                }
            }
        }.apply { isDaemon = true; start() }

        override fun close() = socket.close()
    }

    /** A fake Morganite on 127.0.0.1:24242 and an origin, both real sockets. */
    @Test
    fun `interceptor serves from the cache and falls back to the origin`() {
        val seen = java.util.Collections.synchronizedList(mutableListOf<String>())
        var cacheHas = true
        var cacheBody = "from-cache"
        // The URL's hash is the real hash of what the cache serves.
        val hash = java.security.MessageDigest.getInstance("SHA-256").digest("from-cache".toByteArray())
            .joinToString("") { "%02x".format(it) }
        val cache = try {
            TinyServer(24242) { _, target ->
                when {
                    target == "/" -> 200 to ""
                    cacheHas -> { seen += target; 200 to cacheBody }
                    else -> 404 to ""
                }
            }
        } catch (e: java.net.BindException) {
            return // something already holds 24242 on this machine
        }
        val origin = TinyServer(0) { _, _ -> 200 to "from-origin" }
        try {
            val client = okhttp3.OkHttpClient.Builder()
                .addInterceptor(LocalBlossomCache.interceptor)
                // "origin.test" must not look like this phone, or the cache is skipped.
                .dns(object : okhttp3.Dns {
                    override fun lookup(hostname: String): List<java.net.InetAddress> =
                        if (hostname == "origin.test") listOf(java.net.InetAddress.getByName("127.0.0.1"))
                        else okhttp3.Dns.SYSTEM.lookup(hostname)
                })
                .build()
            val url = "http://origin.test:${origin.port}/$hash.jpg"
            fun get() = client.newCall(okhttp3.Request.Builder().url(url).build()).execute().use { it.body!!.string() }

            LocalBlossomCache.enabled = true
            assertEquals("from-cache", get())
            assertEquals("/$hash.jpg?xs=http%3A%2F%2Forigin.test%3A${origin.port}", seen.single())
            // A Range request (video seek) goes straight to the origin.
            assertEquals("from-origin", client.newCall(
                okhttp3.Request.Builder().url(url).header("Range", "bytes=0-").build()
            ).execute().use { it.body!!.string() })
            assertEquals(1, seen.size)

            // Another app on 24242 serving the wrong bytes is not believed.
            cacheBody = "tampered"
            assertEquals("from-origin", get())
            assertEquals(2, seen.size)

            cacheHas = false
            assertEquals("from-origin", get())

            LocalBlossomCache.enabled = false
            cacheHas = true
            cacheBody = "from-cache"
            assertEquals("from-origin", get())
            assertEquals(2, seen.size)
        } finally {
            LocalBlossomCache.enabled = true
            cache.close(); origin.close()
        }
    }
}
