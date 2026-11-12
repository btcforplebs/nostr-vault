package com.nostrvault.service

import com.nostrvault.ui.screens.BlossomMediaItem
import com.nostrvault.ui.screens.listedUploaded
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** The date a copied-in file carries on disk (iOS CopiedInDate). */
class CopiedInDateTest {
    @get:Rule val tmp = TemporaryFolder()

    private val hash = "a".repeat(64)
    private val day = 86_400L
    private val now = 1_800_000_000_000L

    @Test
    fun `a link in several notes takes the newest note's date`() {
        val notes = listOf("u1" to 100L, "u2" to 50L, "u1" to 300L, "u1" to 200L)
        assertEquals(mapOf("u1" to 300L, "u2" to 50L), CopiedInDate.newestByKey(notes, { it.first }, { it.second }))
    }

    @Test
    fun `the earliest server upload time wins and empty times are skipped`() {
        val blobs = listOf(
            BlobDescriptor(sha256 = hash.uppercase(), uploaded = 500L),
            BlobDescriptor(sha256 = hash, uploaded = 200L),
            BlobDescriptor(sha256 = hash, uploaded = 0L),
            BlobDescriptor(sha256 = "b".repeat(64), uploaded = null),
            BlobDescriptor(sha256 = null, uploaded = 10L),
        )
        assertEquals(mapOf(hash to 200L), CopiedInDate.uploadedByHash(blobs))
    }

    @Test
    fun `a copy is stamped with the photo's date, bare or with an extension`() {
        val dir = tmp.root
        val bare = java.io.File(dir, hash).apply { writeText("x"); setLastModified(now) }
        val other = "c".repeat(64)
        val withExt = java.io.File(dir, "$other.jpg").apply { writeText("y"); setLastModified(now) }
        assertTrue(CopiedInDate.stamp(hash, dir, 1_000 * day, writtenSince = now - 5_000, now = now))
        assertTrue(CopiedInDate.stamp(other, dir, 2_000 * day, writtenSince = now - 5_000, now = now))
        assertEquals(1_000 * day * 1000, bare.lastModified())
        assertEquals(2_000 * day * 1000, withExt.lastModified())
    }

    @Test
    fun `no date, a future date or no stored file leaves it alone`() {
        val f = java.io.File(tmp.root, hash).apply { writeText("x"); setLastModified(now) }
        assertFalse(CopiedInDate.stamp(hash, tmp.root, null, writtenSince = 0, now = now))
        assertFalse(CopiedInDate.stamp(hash, tmp.root, now / 1000 + day, writtenSince = 0, now = now))
        assertFalse(CopiedInDate.stamp(hash, tmp.root, 0L, writtenSince = 0, now = now))
        assertFalse(CopiedInDate.stamp("d".repeat(64), tmp.root, 1_000 * day, writtenSince = 0, now = now))
        assertEquals(now, f.lastModified())
    }

    @Test
    fun `a file that was already here before this copy keeps its date`() {
        val old = now - 30 * day * 1000
        val f = java.io.File(tmp.root, hash).apply { writeText("x"); setLastModified(old) }
        assertFalse(CopiedInDate.stamp(hash, tmp.root, 1_000 * day, writtenSince = now - 5_000, now = now))
        assertEquals(old, f.lastModified())
    }

    @Test
    fun `the vault's own list time is not a file's date, an outside server's is`() {
        val local = BlossomMediaItem(hash, "/v/$hash", null, null, null, uploaded = null, lastModified = now, isLocal = true)
        assertNull(listedUploaded(local, listed = 1_000L, fromThisVault = true))
        assertEquals(1_000L, listedUploaded(local, listed = 1_000L, fromThisVault = false))
        assertEquals(900L, listedUploaded(local.copy(uploaded = 900L), listed = 1_000L, fromThisVault = false))
        assertEquals(900L, listedUploaded(local.copy(uploaded = 900L), listed = 1_000L, fromThisVault = true))
    }
}
