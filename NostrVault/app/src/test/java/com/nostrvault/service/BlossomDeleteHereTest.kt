package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenConfig
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** "Delete from this device" (D3): fail closed unless an outside server holds the file, checked now. */
class BlossomDeleteHereTest {
    private val sha = "c".repeat(64)
    private val owner = "o".repeat(64)
    private val tempDirs = mutableListOf<File>()

    @After fun cleanUp() { tempDirs.forEach { it.deleteRecursively() } }

    private fun tempDir(): File = Files.createTempDirectory("deletehere").toFile().also { tempDirs += it }

    private fun vault(): Pair<File, File> {
        val dir = tempDir()
        val blob = File(File(dir, "blossom").apply { mkdirs() }, sha).apply { writeBytes(ByteArray(5) { 7 }) }
        return dir to blob
    }

    private fun service(
        dataDir: File,
        mirrors: List<String>,
        removed: DeviceRemovedHashes = DeviceRemovedHashes(dir = null),
        published: List<String> = emptyList(),
    ): BlossomService {
        val configStore = mockk<ConfigStore>(relaxed = true)
        every { configStore.config } returns MutableStateFlow(
            HavenConfig(ownerNpub = "npub1owner", blossomMirrors = mirrors, relayDataDir = dataDir.absolutePath),
        )
        val nostr = mockk<NostrService>(relaxed = true)
        every { nostr.ownerHexPubkey } returns owner
        every { nostr.serverLists } returns MutableStateFlow(mapOf(owner to published))
        return BlossomService(
            configStore, nostr, mockk(relaxed = true), mockk(relaxed = true), mockk(relaxed = true),
            removedHere = removed,
        ).apply { serverOwner = { _, _ -> BlossomService.ServerOwner.OTHER } }
    }

    @Test
    fun `removes the vault file and marks it when an outside server holds it`() = runTest {
        val (dir, blob) = vault()
        val removed = DeviceRemovedHashes(dir = null)
        val asked = mutableListOf<Pair<String, Long>>()
        val svc = service(dir, listOf("https://cdn.example.com", "https://down.example.com"), removed)
        svc.heldCopyProbe = { server, _, len -> asked += server to len; server == "https://cdn.example.com" }
        val result = svc.deleteFromThisDevice(sha)
        assertEquals(DeleteHereResult.Removed(freedBytes = 5, heldBy = 1), result)
        assertFalse(blob.exists())
        assertTrue(removed.isRemoved(owner, sha))
        // Each server is asked for this file's own length.
        assertEquals(setOf("https://cdn.example.com" to 5L, "https://down.example.com" to 5L), asked.toSet())
    }

    @Test
    fun `keeps the file when no server holds it, and does not mark it`() = runTest {
        val (dir, blob) = vault()
        val removed = DeviceRemovedHashes(dir = null)
        val svc = service(dir, listOf("https://cdn.example.com"), removed)
        svc.heldCopyProbe = { _, _, _ -> false }
        assertEquals(DeleteHereResult.Kept(DELETE_HERE_NO_COPY), svc.deleteFromThisDevice(sha))
        assertTrue(blob.exists())
        assertFalse(removed.isRemoved(owner, sha))
    }

    @Test
    fun `keeps the file with no media servers at all`() = runTest {
        val (dir, blob) = vault()
        val svc = service(dir, emptyList())
        svc.heldCopyProbe = { _, _, _ -> error("nothing to ask") }
        assertEquals(DeleteHereResult.Kept(DELETE_HERE_NO_COPY), svc.deleteFromThisDevice(sha))
        assertTrue(blob.exists())
    }

    @Test
    fun `the owner's own Mac or box never counts, under any name`() = runTest {
        val (dir, blob) = vault()
        // A LAN box and a .local Mac are never asked; a public name the owner runs is asked who runs it.
        val svc = service(dir, listOf("https://192.168.4.99:3355", "https://studio.local"), published = listOf("https://logen.example.com"))
        val probed = mutableListOf<String>()
        svc.serverOwner = { server, _ -> probed += server; BlossomService.ServerOwner.OWNER }
        svc.heldCopyProbe = { _, _, _ -> true }
        assertEquals(DeleteHereResult.Kept(DELETE_HERE_NO_COPY), svc.deleteFromThisDevice(sha))
        assertEquals(listOf("https://logen.example.com"), probed)
        assertTrue(blob.exists())
    }

    @Test
    fun `a server that cannot say who runs it does not count`() = runTest {
        val (dir, blob) = vault()
        val svc = service(dir, listOf("https://tunnel.example.com"))
        svc.serverOwner = { _, _ -> BlossomService.ServerOwner.UNKNOWN }
        svc.heldCopyProbe = { _, _, _ -> true }
        assertEquals(DeleteHereResult.Kept(DELETE_HERE_NO_COPY), svc.deleteFromThisDevice(sha))
        assertTrue(blob.exists())
    }

    @Test
    fun `no saved mark, no delete`() = runTest {
        val (dir, blob) = vault()
        // A plain file where the list's folder should be: every save fails.
        val notADir = File(tempDir(), "file").apply { writeText("x") }
        val svc = service(dir, listOf("https://cdn.example.com"), DeviceRemovedHashes(notADir))
        svc.heldCopyProbe = { _, _, _ -> true }
        assertEquals(DeleteHereResult.Kept(DELETE_HERE_NO_SAVE), svc.deleteFromThisDevice(sha))
        assertTrue(blob.exists())
    }

    @Test
    fun `nothing here to delete`() = runTest {
        val dir = tempDir()
        val svc = service(dir, listOf("https://cdn.example.com"))
        svc.heldCopyProbe = { _, _, _ -> true }
        assertEquals(DeleteHereResult.NotHere, svc.deleteFromThisDevice(sha))
        assertEquals(DeleteHereResult.NotHere, svc.deleteFromThisDevice("not-a-hash"))
    }

    // ── Delete from mirrors after Delete from this device (Tron, #2649) ──

    @Test
    fun `delete from mirrors is refused once this device's copy is gone`() = runTest {
        val (dir, blob) = vault()
        val removed = DeviceRemovedHashes(dir = null)
        val svc = service(dir, listOf("https://cdn.example.com"), removed)
        svc.heldCopyProbe = { _, _, _ -> true }
        assertTrue(svc.deleteFromThisDevice(sha) is DeleteHereResult.Removed)
        assertFalse(blob.exists())
        // The servers that proved they hold it are the ones this delete would reach: not asked at all.
        svc.serverOwner = { _, _ -> error("mirror delete reached a server") }
        val report = svc.deleteFromServers(sha, photoUrl = null, includeHomeVault = false)
        assertTrue(report.refusedLastCopy)
        assertTrue(report.deleted.isEmpty() && report.failed.isEmpty())
        assertEquals(DELETE_MIRRORS_LAST_COPY to false, mirrorsDeleteMessage(report))
    }

    @Test
    fun `a mark with the file back here does not refuse delete from mirrors`() = runTest {
        val (dir, _) = vault()
        val removed = DeviceRemovedHashes(dir = null).apply { assertTrue(markRemoved("d".repeat(64), sha)) }
        val svc = service(dir, listOf("https://cdn.example.com"), removed)
        var asked = 0
        svc.serverOwner = { _, _ -> asked++; BlossomService.ServerOwner.OWNER }
        val report = svc.deleteFromServers(sha, photoUrl = null, includeHomeVault = false)
        assertFalse(report.refusedLastCopy)
        assertEquals(1, asked)
    }

    // ── One answer as proof ─────────────────────────────────────

    @Test
    fun `an answer proves a copy only with this file's length`() {
        val p = BlobPresence.PRESENT
        assertTrue(deleteHereHolds(p, 206, "bytes 0-0/5", "1", 5))
        assertTrue(deleteHereHolds(p, 200, null, "5", 5))
        // A different size is another file (or a placeholder).
        assertFalse(deleteHereHolds(p, 206, "bytes 0-0/9", "1", 5))
        assertFalse(deleteHereHolds(p, 200, null, "9", 5))
        // No size given is not proof.
        assertFalse(deleteHereHolds(p, 206, null, "1", 5))
        assertFalse(deleteHereHolds(p, 206, "bytes 0-0/*", "1", 5))
        assertFalse(deleteHereHolds(p, 200, null, null, 5))
        // 206's Content-Length is the 1-byte range, never the file.
        assertFalse(deleteHereHolds(p, 206, null, "5", 5))
        assertFalse(deleteHereHolds(BlobPresence.ABSENT, 206, "bytes 0-0/5", "1", 5))
        assertFalse(deleteHereHolds(BlobPresence.UNREACHABLE, 206, "bytes 0-0/5", "1", 5))
    }

    @Test
    fun `a cached answer is not proof`() {
        val p = BlobPresence.PRESENT
        assertTrue(deleteHereHolds(p, 206, "bytes 0-0/5", "1", 5, cacheStatus = "MISS", age = "0"))
        assertTrue(deleteHereHolds(p, 206, "bytes 0-0/5", "1", 5, cacheStatus = "DYNAMIC"))
        assertFalse(deleteHereHolds(p, 206, "bytes 0-0/5", "1", 5, cacheStatus = "HIT"))
        assertFalse(deleteHereHolds(p, 206, "bytes 0-0/5", "1", 5, cacheStatus = "stale"))
        assertFalse(deleteHereHolds(p, 206, "bytes 0-0/5", "1", 5, age = "120"))
    }

    // ── The removed-here list ───────────────────────────────────

    @Test
    fun `the list is per account, survives a restart, and Save to Vault clears it`() {
        val dir = tempDir()
        val other = "a".repeat(64)
        val first = DeviceRemovedHashes(dir)
        assertTrue(first.markRemoved(owner, sha.uppercase()))
        assertTrue(first.isRemoved(owner, sha))
        assertFalse(first.isRemoved(other, sha))
        assertFalse(first.markRemoved(owner, "short"))

        val reread = DeviceRemovedHashes(dir)
        assertEquals(setOf(sha), reread.removed(owner))
        reread.allow(sha)
        assertFalse(reread.isRemoved(owner, sha))
        assertFalse(DeviceRemovedHashes(dir).isRemoved(owner, sha))
    }
}
