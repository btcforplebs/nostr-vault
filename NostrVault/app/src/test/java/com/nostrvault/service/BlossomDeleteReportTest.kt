package com.nostrvault.service

import android.util.Base64
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.fips.DeviceRole
import com.nostrvault.fips.FipsDevice
import com.nostrvault.fips.FipsMeshSettings
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
 * [BlossomService.deleteFromServers] now reports each server, and
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

    private fun service(
        mirrors: List<String>,
        dataDir: File? = null,
        published: List<String> = emptyList(),
        macs: List<FipsDevice> = emptyList(),
    ): BlossomService {
        val configStore = mockk<ConfigStore>(relaxed = true)
        every { configStore.config } returns MutableStateFlow(
            HavenConfig(
                ownerNpub = "npub1owner", blossomMirrors = mirrors, relayDataDir = dataDir?.absolutePath,
                fipsPeers = macs.map { it.npub }, fipsMesh = FipsMeshSettings(devices = macs),
            )
        )
        val signer = mockk<NostrService>(relaxed = true)
        every { signer.ownerHexPubkey } returns "o".repeat(64)
        every { signer.serverLists } returns MutableStateFlow(mapOf("o".repeat(64) to published))
        coEvery { signer.signEventAsync(any(), any(), any(), any(), any()) } returns NostrEvent(
            id = "e".repeat(64), pubkey = "p".repeat(64), createdAt = 1_700_000_000L,
            kind = 24242, tags = listOf(listOf("t", "delete")), content = "Blossom delete", sig = "s".repeat(128),
        )
        return BlossomService(configStore, signer, mockk(relaxed = true), mockk(relaxed = true), mockk(relaxed = true))
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
        val report = service(listOf(a, b)).deleteFromServers(sha, photoUrl = null, includeHomeVault = true)
        assertEquals(listOf(a, b), report.deleted)
        assertTrue(report.failed.isEmpty())
        assertTrue(report.allDeleted)
    }

    @Test
    fun `one mirror refusing is not all deleted`() = runTest {
        val ok = mirror(200); val refuses = mirror(401)
        val report = service(listOf(ok, refuses)).deleteFromServers(sha, photoUrl = null, includeHomeVault = true)
        assertFalse(report.allDeleted)
        assertEquals(listOf(refuses), report.failed)
        assertEquals(listOf("127.0.0.1"), report.failedHosts)
    }

    @Test
    fun `a 404 counts as deleted`() = runTest {
        val report = service(listOf(mirror(404))).deleteFromServers(sha, photoUrl = null, includeHomeVault = true)
        assertTrue(report.allDeleted)
    }

    @Test
    fun `an unreachable mirror counts as failed`() = runTest {
        // Port 9 (discard): nothing listens, the connection is refused.
        val report = service(listOf(mirror(200), "http://127.0.0.1:9")).deleteFromServers(sha, photoUrl = null, includeHomeVault = true)
        assertEquals(listOf("http://127.0.0.1:9"), report.failed)
        assertFalse(report.allDeleted)
    }

    @Test
    fun `no mirrors is neither deleted nor failed`() = runTest {
        val report = service(emptyList()).deleteFromServers(sha, photoUrl = null, includeHomeVault = true)
        assertFalse(report.allDeleted)
        assertTrue(report.failed.isEmpty())
    }

    @Test
    fun `the 10063 servers and the photo's host are asked too`() = runTest {
        // Tim 2026-10-31: a file on a server only the published list or the
        // photo URL named stayed public after "Delete from mirrors".
        val configured = mirror(200); val listed = mirror(200); val posted = mirror(200)
        val report = service(listOf(configured), published = listOf(listed, configured))
            .deleteFromServers(sha, photoUrl = "$posted/$sha.jpg", includeHomeVault = true)
        // Loopback photo hosts are this phone's vault and skipped; the test
        // servers are loopback, so only the two listed servers are asked here.
        assertEquals(listOf(configured, listed), report.deleted)
        assertTrue(report.allDeleted)
    }

    // ── Mesh devices ────────────────────────────────────────────

    private val macNpub = "npub1qgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpq2yz0cn"
    private val mac = FipsDevice(macNpub, DeviceRole.MAC, name = "Studio Mac")

    /**
     * A Mac vault behind the mesh ingress (`<base>/<token>/<sha>`). [hasDelete] false is its mesh
     * door, which a phone not in the Mac's My Devices reaches: no DELETE, so the file stays.
     */
    private fun meshVault(hasDelete: Boolean = true, requests: MutableList<String> = mutableListOf()): String {
        var held = true
        val port = startServer { method, path ->
            synchronized(requests) { requests += "$method $path" }
            when {
                path != "/tok/$sha" -> 400 to ByteArray(0)
                method == "DELETE" && hasDelete -> { held = false; 204 to ByteArray(0) }
                method == "DELETE" -> 404 to ByteArray(0)
                method == "HEAD" -> (if (held) 200 else 404) to ByteArray(0)
                else -> 400 to ByteArray(0)
            }
        }
        return "http://127.0.0.1:$port/tok"
    }

    @Test
    fun `delete everywhere reaches a mesh-only mac`() = runTest {
        val requests = mutableListOf<String>()
        val base = meshVault(requests = requests)
        val svc = service(listOf(mirror(200)), macs = listOf(mac))
        svc.meshIngress = { if (it == macNpub) base else null }
        val report = svc.deleteFromServers(sha, photoUrl = null, includeHomeVault = true)
        assertTrue(report.allDeleted)
        assertTrue("fipsmesh://$macNpub/" in report.deleted)
        // The DELETE, then the HEAD that proves it gone.
        assertEquals(listOf("DELETE /tok/$sha", "HEAD /tok/$sha"), requests)
    }

    @Test
    fun `a mac whose door has no delete is named, not counted gone`() = runTest {
        val svc = service(emptyList(), macs = listOf(mac))
        svc.meshIngress = { meshVault(hasDelete = false) }
        val report = svc.deleteFromServers(sha, photoUrl = null, includeHomeVault = true)
        assertFalse(report.allDeleted)
        assertEquals("Still on Studio Mac", deleteEverywhereLeftover(localDeleted = true, mirrors = report))
    }

    @Test
    fun `an unreachable mac is still on the list`() = runTest {
        val svc = service(listOf(mirror(200)), macs = listOf(mac))
        svc.meshIngress = { null }
        val report = svc.deleteFromServers(sha, photoUrl = null, includeHomeVault = true)
        assertEquals(listOf("fipsmesh://$macNpub/"), report.failed)
        assertEquals(listOf("Studio Mac"), report.failedHosts)
    }

    @Test
    fun `a link still coming up is retried`() = runTest {
        val base = meshVault()
        var forgotten = false
        val svc = service(emptyList(), macs = listOf(mac))
        // First dial: nothing listening (port 9); after the dropped link is forgotten, the vault.
        svc.meshIngress = { if (forgotten) base else "http://127.0.0.1:9/tok" }
        svc.meshForget = { forgotten = true }
        svc.meshRetryDelayMs = 10
        assertTrue(svc.deleteFromServers(sha, photoUrl = null, includeHomeVault = true).allDeleted)
    }

    @Test
    fun `delete from mirrors never dials the mesh`() = runTest {
        var dialled = false
        val svc = service(listOf(mirror(200)), macs = listOf(mac))
        svc.meshIngress = { dialled = true; null }
        svc.deleteFromServers(sha, photoUrl = null, includeHomeVault = false)
        assertFalse(dialled)
    }

    // ── The owner's own vaults ──────────────────────────────────
    // Tron ship check 2026-10-31: "Delete from mirrors" skipped only the Mac
    // URL this device knows; the same vault under another name got the delete.

    @Test
    fun `delete from mirrors keeps a server the owner runs`() = runTest {
        val otherPhonesMac = "https://studio-mac.example.net"
        val asked = mutableListOf<String>()
        val svc = service(emptyList(), published = listOf(otherPhonesMac))
        svc.serverOwner = { server, owner -> asked += server; assertEquals("o".repeat(64), owner); BlossomService.ServerOwner.OWNER }
        val report = svc.deleteFromServers(sha, photoUrl = "$otherPhonesMac/$sha.jpg", includeHomeVault = false)
        assertEquals(listOf(otherPhonesMac), asked)
        // No DELETE went out: it would have failed (no such host) and been listed.
        assertTrue(report.deleted.isEmpty())
        assertTrue(report.failed.isEmpty())
    }

    @Test
    fun `a server that cannot say who runs it is not deleted from`() = runTest {
        val svc = service(emptyList(), published = listOf("https://maybe-mine.example.net"))
        svc.serverOwner = { _, _ -> BlossomService.ServerOwner.UNKNOWN }
        val report = svc.deleteFromServers(sha, photoUrl = null, includeHomeVault = false)
        assertEquals(listOf("https://maybe-mine.example.net"), report.failed)
        assertEquals(listOf("maybe-mine.example.net"), report.failedHosts)
    }

    @Test
    fun `delete everywhere does not ask who runs a server`() = runTest {
        val svc = service(listOf(mirror(200)))
        svc.serverOwner = { _, _ -> error("asked") }
        assertTrue(svc.deleteFromServers(sha, photoUrl = null, includeHomeVault = true).allDeleted)
    }

    private fun infoServer(code: Int, body: String): String {
        val port = startServer { method, path ->
            if (method == "GET" && path == "/") code to body.toByteArray() else 400 to ByteArray(0)
        }
        return "http://127.0.0.1:$port"
    }

    @Test
    fun `a haven vault names its owner in its relay info`() {
        val owner = "a".repeat(64)
        val svc = service(emptyList())
        val vault = infoServer(200, """{"name":"outbox","pubkey":"${owner.uppercase()}","software":"https://github.com/barrydeen/haven"}""")
        assertEquals(BlossomService.ServerOwner.OWNER, svc.askServerOwner("$vault/$sha.jpg", owner))
        assertEquals(BlossomService.ServerOwner.OTHER, svc.askServerOwner(vault, "b".repeat(64)))
        assertEquals(BlossomService.ServerOwner.OTHER, svc.askServerOwner(vault, ""))
    }

    @Test
    fun `other answers are someone else's server, no answer is unknown`() {
        val owner = "a".repeat(64)
        val svc = service(emptyList())
        assertEquals(BlossomService.ServerOwner.OTHER, svc.askServerOwner(infoServer(200, "<html>blossom</html>"), owner))
        assertEquals(BlossomService.ServerOwner.OTHER, svc.askServerOwner(infoServer(404, ""), owner))
        assertEquals(BlossomService.ServerOwner.UNKNOWN, svc.askServerOwner(infoServer(502, ""), owner))
        assertEquals(BlossomService.ServerOwner.UNKNOWN, svc.askServerOwner("http://127.0.0.1:9", owner))
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

    // ── No hash ─────────────────────────────────────────────────

    @Test
    fun `only a 64-hex hash can be deleted`() {
        assertTrue(isBlobHash(sha))
        assertTrue(isBlobHash("A".repeat(64)))
        assertFalse(isBlobHash(""))
        assertFalse(isBlobHash("photo"))  // a link's last path part, not a hash
        assertFalse(isBlobHash("b".repeat(63)))
        assertFalse(isBlobHash("g".repeat(64)))
        assertEquals("Can't delete: this file's hash could not be read", DELETE_NO_HASH_MESSAGE)
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
