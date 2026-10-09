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
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.file.Files

/**
 * "Delete everywhere" used to say so when any one server deleted the file.
 * [BlossomService.deleteFromMirrors] now reports each server, and
 * [deleteEverywhereLeftover] names every place the file is still on.
 * Port of the iOS checks in #458.
 */
class BlossomDeleteReportTest {

    private val sha = "b".repeat(64)
    private val servers = mutableListOf<ServerSocket>()
    private val tempDirs = mutableListOf<File>()

    init {
        mockkStatic(Base64::class)
        every { Base64.encodeToString(any(), any()) } returns "signed-auth-header"
    }

    @After
    fun cleanUp() {
        servers.forEach { it.close() }
        tempDirs.forEach { it.deleteRecursively() }
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

    /** A mirror answering every DELETE with [code]. */
    private fun mirror(code: Int): String {
        val port = startServer { method, path ->
            if (method == "DELETE" && path == "/$sha") code to ByteArray(0) else 400 to ByteArray(0)
        }
        return "http://127.0.0.1:$port"
    }

    private fun service(mirrors: List<String>, dataDir: File? = null): BlossomService {
        val configStore = mockk<ConfigStore>(relaxed = true)
        every { configStore.config } returns MutableStateFlow(
            HavenConfig(ownerNpub = "npub1owner", blossomMirrors = mirrors, relayDataDir = dataDir?.absolutePath)
        )
        val signer = mockk<NostrService>(relaxed = true)
        coEvery { signer.signEventAsync(any(), any(), any(), any(), any()) } returns NostrEvent(
            id = "e".repeat(64), pubkey = "p".repeat(64), createdAt = 1_700_000_000L,
            kind = 24242, tags = listOf(listOf("t", "delete")), content = "Blossom delete", sig = "s".repeat(128),
        )
        return BlossomService(configStore, signer, mockk(relaxed = true))
    }

    private fun dataDir(withBlob: Boolean): File {
        val dir = Files.createTempDirectory("relay").toFile().also { tempDirs += it }
        val blossom = File(dir, "blossom").apply { mkdirs() }
        if (withBlob) File(blossom, sha).writeBytes(byteArrayOf(1, 2, 3))
        return dir
    }

    // ── Mirrors ─────────────────────────────────────────────────

    @Test
    fun `every mirror deleting is all deleted`() = runTest {
        val a = mirror(200); val b = mirror(204)
        val report = service(listOf(a, b)).deleteFromMirrors(sha)
        assertEquals(listOf(a, b), report.deleted)
        assertTrue(report.failed.isEmpty())
        assertTrue(report.allDeleted)
    }

    @Test
    fun `one mirror refusing is not all deleted`() = runTest {
        val ok = mirror(200); val refuses = mirror(401)
        val report = service(listOf(ok, refuses)).deleteFromMirrors(sha)
        assertFalse(report.allDeleted)
        assertEquals(listOf(refuses), report.failed)
        assertEquals(listOf("127.0.0.1"), report.failedHosts)
    }

    @Test
    fun `a 404 counts as deleted`() = runTest {
        val report = service(listOf(mirror(404))).deleteFromMirrors(sha)
        assertTrue(report.allDeleted)
    }

    @Test
    fun `an unreachable mirror counts as failed`() = runTest {
        // Port 9 (discard): nothing listens, the connection is refused.
        val report = service(listOf(mirror(200), "http://127.0.0.1:9")).deleteFromMirrors(sha)
        assertEquals(listOf("http://127.0.0.1:9"), report.failed)
        assertFalse(report.allDeleted)
    }

    @Test
    fun `no mirrors is neither deleted nor failed`() = runTest {
        val report = service(emptyList()).deleteFromMirrors(sha)
        assertFalse(report.allDeleted)
        assertTrue(report.failed.isEmpty())
    }

    // ── This device ─────────────────────────────────────────────

    @Test
    fun `a local blob is deleted`() {
        val dir = dataDir(withBlob = true)
        assertTrue(service(emptyList(), dir).deleteFromLocal(sha))
        assertFalse(File(dir, "blossom/$sha").exists())
    }

    @Test
    fun `a blob already missing from this device counts as deleted`() {
        assertTrue(service(emptyList(), dataDir(withBlob = false)).deleteFromLocal(sha))
    }

    // ── What is left ────────────────────────────────────────────

    @Test
    fun `nothing left is no message`() {
        val mirrors = BlossomService.MirrorDeleteResult(deleted = listOf("https://blossom.band"))
        assertNull(deleteEverywhereLeftover(localDeleted = true, mirrors = mirrors))
    }

    @Test
    fun `leftover names every server and this device`() {
        val mirrors = BlossomService.MirrorDeleteResult(
            deleted = listOf("https://blossom.band"),
            failed = listOf("https://blossom.primal.net", "https://nostr.download/"),
        )
        assertEquals(
            "Still on blossom.primal.net and nostr.download",
            deleteEverywhereLeftover(localDeleted = true, mirrors = mirrors),
        )
        assertEquals(
            "Still on blossom.primal.net, nostr.download and this device",
            deleteEverywhereLeftover(localDeleted = false, mirrors = mirrors),
        )
    }

    @Test
    fun `only this device left`() {
        assertEquals(
            "Still on this device",
            deleteEverywhereLeftover(localDeleted = false, mirrors = BlossomService.MirrorDeleteResult()),
        )
    }

    // ── Presence after a delete ─────────────────────────────────

    @Test
    fun `a redirect to a placeholder reads absent`() {
        assertEquals(
            BlobPresence.ABSENT,
            blobPresence(200, "image/png", "4096", sha256 = sha, finalUrl = "https://cdn.example.com/404.png"),
        )
    }

    @Test
    fun `a blob served at its own hash reads present`() {
        assertEquals(
            BlobPresence.PRESENT,
            blobPresence(206, "image/png", "1", sha256 = sha, finalUrl = "https://blossom.band/${sha.uppercase()}.png"),
        )
    }
}
