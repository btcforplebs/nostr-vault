package com.nostrvault.service

import android.util.Base64
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenConfig
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.Collections

/**
 * "Push to mirrors" in the Media tab used to say "Pushed to mirrors" whatever
 * happened. [BlossomService.pushLocalToMirrors] now reports how many of the
 * servers it tried accepted the blob, and the viewer's message follows that.
 *
 * The local relay and the mirrors are tiny HTTP/1.1 servers on 127.0.0.1 (the
 * unit-test classpath is android.jar, so no JDK HttpServer): a mirror that
 * answers 500 refuses every upload, one that answers 200 accepts.
 */
class BlossomMirrorPushTest {

    private val sha = "a".repeat(64)
    private val blob = ByteArray(32) { it.toByte() }
    private val servers = mutableListOf<ServerSocket>()

    /** Upload paths each mirror received, keyed by the mirror's base URL. */
    private val uploads = Collections.synchronizedList(mutableListOf<String>())

    init {
        mockkStatic(Base64::class)
        every { Base64.encodeToString(any(), any()) } returns "signed-auth-header"
    }

    @After
    fun stopServers() {
        servers.forEach { it.close() }
    }

    private fun startServer(handler: (method: String, path: String) -> Pair<Int, ByteArray>): Int {
        val server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
        servers += server
        Thread {
            while (!server.isClosed) {
                val socket = try { server.accept() } catch (_: Exception) { break }
                Thread { serve(socket, handler) }.apply { isDaemon = true }.start()
            }
        }.apply { isDaemon = true }.start()
        return server.localPort
    }

    /** One request per connection; `Connection: close` keeps OkHttp from reusing it. */
    private fun serve(socket: Socket, handler: (String, String) -> Pair<Int, ByteArray>) = socket.use {
        val input = it.getInputStream().buffered()
        fun line(): String {
            val sb = StringBuilder()
            while (true) {
                val c = input.read()
                if (c == -1 || c == '\n'.code) break
                if (c != '\r'.code) sb.append(c.toChar())
            }
            return sb.toString()
        }
        val request = line().split(' ')
        if (request.size < 2) return@use
        var length = 0
        while (true) {
            val header = line()
            if (header.isEmpty()) break
            if (header.lowercase().startsWith("content-length:")) length = header.substringAfter(':').trim().toInt()
        }
        repeat(length) { input.read() }
        val (code, body) = handler(request[0], request[1].substringBefore('?'))
        val out = it.getOutputStream()
        out.write(
            ("HTTP/1.1 $code X\r\nContent-Type: image/png\r\nContent-Length: ${body.size}\r\n" +
                "Connection: close\r\n\r\n").toByteArray()
        )
        out.write(body)
        out.flush()
    }

    /** This device's relay, holding [blob] (or nothing when [hasBlob] is false). */
    private fun localRelay(hasBlob: Boolean = true): Int = startServer { method, path ->
        if (method == "GET" && path == "/$sha" && hasBlob) 200 to blob else 404 to ByteArray(0)
    }

    private fun mirror(accepts: Boolean): String {
        lateinit var base: String
        val port = startServer { method, path ->
            if (method == "PUT" && path == "/upload") uploads += base
            (if (accepts) 200 else 500) to ByteArray(0)
        }
        base = "http://127.0.0.1:$port"
        return base
    }

    private fun service(relayPort: Int, mirrors: List<String>, signer: NostrService = signer()): BlossomService {
        val configStore = mockk<ConfigStore>(relaxed = true)
        every { configStore.config } returns MutableStateFlow(
            HavenConfig(ownerNpub = "npub1owner", blossomMirrors = mirrors, relayPort = relayPort)
        )
        return BlossomService(configStore, signer, mockk(relaxed = true))
    }

    private fun signer(): NostrService = mockk<NostrService>(relaxed = true).also {
        coEvery { it.signEventAsync(any(), any(), any(), any(), any()) } returns NostrEvent(
            id = "e".repeat(64), pubkey = "p".repeat(64), createdAt = 1_700_000_000L,
            kind = 24242, tags = listOf(listOf("t", "upload")), content = "Blossom upload", sig = "s".repeat(128),
        )
    }

    // ── End to end ──────────────────────────────────────────────

    @Test
    fun `every server accepting is all accepted`() = runTest {
        val result = service(localRelay(), listOf(mirror(true), mirror(true))).pushLocalToMirrors(sha)
        assertEquals(BlossomService.MirrorPushResult.AllAccepted(2), result)
        assertEquals("Pushed to mirrors", result.message)
        assertTrue(result.anyAccepted)
    }

    @Test
    fun `one server refusing is partial, not pushed`() = runTest {
        val result = service(localRelay(), listOf(mirror(true), mirror(false))).pushLocalToMirrors(sha)
        assertEquals(BlossomService.MirrorPushResult.Partial(accepted = 1, attempted = 2), result)
        assertEquals("Mirrored to 1 of 2 Blossom servers", result.message)
    }

    @Test
    fun `every server refusing is all failed, not pushed`() = runTest {
        val result = service(localRelay(), listOf(mirror(false), mirror(false))).pushLocalToMirrors(sha)
        assertEquals(BlossomService.MirrorPushResult.AllFailed(2), result)
        assertEquals("Could not push to mirrors", result.message)
        assertFalse(result.anyAccepted)
    }

    @Test
    fun `an unreachable server counts as failed`() = runTest {
        // Port 9 (discard): nothing listens, the connection is refused.
        val result = service(localRelay(), listOf(mirror(true), "http://127.0.0.1:9")).pushLocalToMirrors(sha)
        assertEquals(BlossomService.MirrorPushResult.Partial(accepted = 1, attempted = 2), result)
    }

    @Test
    fun `only uploads to the servers asked for`() = runTest {
        val has = mirror(true)
        val missing = mirror(true)
        val result = service(localRelay(), listOf(has, missing)).pushLocalToMirrors(sha, only = setOf(missing))
        assertEquals(BlossomService.MirrorPushResult.AllAccepted(1), result)
        assertEquals(listOf(missing), uploads.toList())
    }

    @Test
    fun `a blob missing from this device is not on device`() = runTest {
        val result = service(localRelay(hasBlob = false), listOf(mirror(true))).pushLocalToMirrors(sha)
        assertEquals(BlossomService.MirrorPushResult.NotOnDevice, result)
        assertTrue(uploads.isEmpty())
    }

    @Test
    fun `no outside server is reported as such`() = runTest {
        val result = service(localRelay(), emptyList()).pushLocalToMirrors(sha)
        assertEquals(BlossomService.MirrorPushResult.NoOutsideServer, result)
    }

    @Test
    fun `an unavailable signer uploads nothing`() = runTest {
        val signer = mockk<NostrService>(relaxed = true)
        coEvery { signer.signEventAsync(any(), any(), any(), any(), any()) } throws SignerRejectedException()
        val result = service(localRelay(), listOf(mirror(true)), signer).pushLocalToMirrors(sha)
        assertEquals(BlossomService.MirrorPushResult.SignerUnavailable, result)
        assertTrue(uploads.isEmpty())
    }

    // ── Counting ────────────────────────────────────────────────

    @Test
    fun `counts map to outcomes`() {
        assertEquals(BlossomService.MirrorPushResult.NoOutsideServer, BlossomService.MirrorPushResult.of(0, 0))
        assertEquals(BlossomService.MirrorPushResult.AllFailed(3), BlossomService.MirrorPushResult.of(0, 3))
        assertEquals(BlossomService.MirrorPushResult.Partial(2, 3), BlossomService.MirrorPushResult.of(2, 3))
        assertEquals(BlossomService.MirrorPushResult.AllAccepted(3), BlossomService.MirrorPushResult.of(3, 3))
    }
}
