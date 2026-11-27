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
        val asked = java.util.Collections.synchronizedList(mutableListOf<Pair<String, Long>>()) // probes run in parallel on IO
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
    fun `the owner's own Mac or box counts as a safe copy, this device's loopback never`() = runTest {
        val (dir, blob) = vault()
        // Logen 2026-11-27: a LAN box or a .local Mac the owner runs holds a real second copy.
        val svc = service(dir, listOf("https://192.168.4.99:3355", "https://studio.local", "http://127.0.0.1:3355"))
        val probed = java.util.Collections.synchronizedList(mutableListOf<String>()) // probes run in parallel on IO
        svc.heldCopyProbe = { server, _, _ -> probed += server; server.contains("192.168.4.99") }
        assertEquals(DeleteHereResult.Removed(freedBytes = 5, heldBy = 1), svc.deleteFromThisDevice(sha))
        assertFalse(probed.any { it.contains("127.0.0.1") })
        assertTrue(probed.any { it.contains("studio.local") })
        assertFalse(blob.exists())
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

    @Test
    fun `the file is out of the vault folder while servers are asked, and back if none holds it`() = runTest {
        val (dir, blob) = vault()
        val removed = DeviceRemovedHashes(dir = null)
        val svc = service(dir, listOf("https://cdn.example.com"), removed)
        var inVaultDuringProbe: Boolean? = null
        var listedDuringProbe: Boolean? = null
        svc.heldCopyProbe = { _, _, _ ->
            inVaultDuringProbe = blob.exists() || svc.vaultFile(sha) != null
            listedDuringProbe = removed.isRemoved(owner, sha)
            false
        }
        assertEquals(DeleteHereResult.Kept(DELETE_HERE_NO_COPY), svc.deleteFromThisDevice(sha))
        // A self-alias (tunnel, LAN name) would now answer 404, never this file (Tron M1).
        assertEquals(false, inVaultDuringProbe)
        assertEquals(true, listedDuringProbe)
        assertTrue(blob.exists())
        assertEquals(5L, blob.length())
        assertFalse(removed.isRemoved(owner, sha))
        assertTrue(File(dir, "removed_here_aside").listFiles { f -> f.isFile }.orEmpty().isEmpty())
        assertTrue(File(dir, "removed_here_aside/unlist").listFiles().orEmpty().isEmpty())
    }

    @Test
    fun `a quit mid-check puts the file back and the list as it was`() = runTest {
        val (dir, blob) = vault()
        val removed = DeviceRemovedHashes(dir = null)
        val svc = service(dir, listOf("https://cdn.example.com"), removed)
        // The app "quits" during the probe: copy what is aside now, as a later start would find it.
        val snapshot = tempDir()
        svc.heldCopyProbe = { _, _, _ -> File(dir, "removed_here_aside").copyRecursively(snapshot, overwrite = true); false }
        svc.deleteFromThisDevice(sha)
        File(dir, "removed_here_aside").deleteRecursively()
        snapshot.copyRecursively(File(dir, "removed_here_aside"))
        blob.delete()
        assertTrue(removed.markRemoved(owner, sha)) // as listed at the moment of the quit
        svc.restoreDeleteHereAside()
        assertEquals(5L, blob.length())
        assertFalse(removed.isRemoved(owner, sha))
    }

    @Test
    fun `a file listed before the check stays listed after a quit mid-check`() = runTest {
        val (dir, blob) = vault()
        val removed = DeviceRemovedHashes(dir = null)
        assertTrue(removed.markRemoved(owner, sha)) // e.g. back from a zip restore, still listed
        val svc = service(dir, listOf("https://cdn.example.com"), removed)
        val snapshot = tempDir()
        svc.heldCopyProbe = { _, _, _ -> File(dir, "removed_here_aside").copyRecursively(snapshot, overwrite = true); false }
        svc.deleteFromThisDevice(sha)
        File(dir, "removed_here_aside").deleteRecursively()
        snapshot.copyRecursively(File(dir, "removed_here_aside"))
        blob.delete()
        svc.restoreDeleteHereAside()
        assertEquals(5L, blob.length())
        assertTrue(removed.isRemoved(owner, sha))
    }

    @Test
    fun `a plain-http LAN server is asked over https only`() = runTest {
        val (dir, blob) = vault()
        val svc = service(dir, listOf("http://192.168.4.20:3355"))
        val probed = java.util.Collections.synchronizedList(mutableListOf<String>())
        svc.heldCopyProbe = { server, _, _ -> probed += server; server.startsWith("http://") }
        assertEquals(DeleteHereResult.Kept(DELETE_HERE_NO_COPY), svc.deleteFromThisDevice(sha))
        assertEquals(listOf("https://192.168.4.20:3355"), probed)
        assertTrue(blob.exists())
    }

    @Test
    fun `a stale unlist mark is cleared when the hash was listed already`() = runTest {
        val (dir, _) = vault()
        val removed = DeviceRemovedHashes(dir = null)
        assertTrue(removed.markRemoved(owner, sha))
        File(File(dir, "removed_here_aside/unlist").apply { mkdirs() }, sha).writeText(owner) // left by a quit
        val svc = service(dir, listOf("https://cdn.example.com"), removed)
        var markDuringProbe: Boolean? = null
        svc.heldCopyProbe = { _, _, _ -> markDuringProbe = File(dir, "removed_here_aside/unlist/$sha").exists(); false }
        svc.deleteFromThisDevice(sha)
        assertEquals(false, markDuringProbe)
        assertTrue(removed.isRemoved(owner, sha))
    }

    @Test
    fun `every vault copy of the hash is out of the folder during the probe`() = runTest {
        val (dir, blob) = vault()
        val withExt = File(blob.parentFile, "$sha.jpg").apply { writeBytes(ByteArray(5) { 7 }) }
        val svc = service(dir, listOf("https://cdn.example.com"))
        var seen: Boolean? = null
        svc.heldCopyProbe = { _, _, _ -> seen = blob.exists() || withExt.exists(); true }
        assertEquals(DeleteHereResult.Removed(freedBytes = 5, heldBy = 1), svc.deleteFromThisDevice(sha))
        assertEquals(false, seen)
        assertFalse(blob.exists() || withExt.exists())
        assertTrue(File(dir, "removed_here_aside").listFiles { f -> f.isFile }.orEmpty().isEmpty())
    }

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
        // A redirect that ended on http proves nothing: anyone on that network could answer.
        assertTrue(deleteHereHolds(p, 206, "bytes 0-0/5", "1", 5, finalUrl = "https://cdn.example.com/$sha"))
        assertFalse(deleteHereHolds(p, 206, "bytes 0-0/5", "1", 5, finalUrl = "http://cdn.example.com/$sha"))
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

    @Test
    fun `an unreadable list is set aside, not saved over`() {
        val dir = tempDir()
        val file = File(dir, "removed_here.json")
        file.writeText("{\"byAccount\":{\"$owner\":[\"$sha\"") // cut short
        val other = "b".repeat(64)
        val removed = DeviceRemovedHashes(dir)
        assertTrue(removed.markRemoved(owner, other))
        val aside = dir.listFiles()!!.filter { it.name.startsWith("removed_here.json.corrupt-") }
        assertEquals(1, aside.size)
        assertTrue(aside.single().readText().contains(sha))
        assertEquals(setOf(other), DeviceRemovedHashes(dir).removed(owner))
    }

    @Test
    fun `a list that can't be read right now is kept, not set aside`() {
        val dir = tempDir()
        // A read error (here: a folder where the file should be), not a bad list.
        val file = File(dir, "removed_here.json").apply { mkdirs() }
        val removed = DeviceRemovedHashes(dir)
        assertFalse(removed.markRemoved(owner, "b".repeat(64)))
        assertTrue(file.isDirectory)
        assertTrue(dir.listFiles()!!.none { it.name.startsWith("removed_here.json.corrupt-") })
    }

    @Test
    fun `an unreadable list that can't be set aside refuses new removals`() {
        val dir = tempDir()
        val file = File(dir, "removed_here.json")
        file.writeText("not json")
        dir.setWritable(false)
        try {
            assertFalse(DeviceRemovedHashes(dir).markRemoved(owner, "b".repeat(64)))
            assertEquals("not json", file.readText())
        } finally {
            dir.setWritable(true)
        }
    }
}
