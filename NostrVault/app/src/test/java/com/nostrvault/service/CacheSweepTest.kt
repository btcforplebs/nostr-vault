package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.nio.file.Files

class CacheSweepTest {
    @get:Rule val tmp = TemporaryFolder()
    private val day = CacheSweep.MAX_AGE_MS
    private val now = System.currentTimeMillis()

    private fun file(name: String, ageMs: Long, bytes: Int = 10, dir: File = tmp.root): File =
        File(dir, name).apply { parentFile?.mkdirs(); writeBytes(ByteArray(bytes)); setLastModified(now - ageMs) }

    @Test fun freshFileWithLiveJobKeptAndTwoDayOldOrphanRemoved() {
        val live = file("import-123.blob", ageMs = 0)
        val oldLive = file("import-456.blob", ageMs = 2 * day)
        val orphan = file("import-789.blob", ageMs = 2 * day, bytes = 2000)
        val held = setOf(live.absolutePath, oldLive.absolutePath)
        val r = CacheSweep.sweep(tmp.root, now, isHeld = { it.absolutePath in held })
        assertTrue(live.exists()); assertTrue(oldLive.exists())
        assertFalse(orphan.exists())
        assertEquals(1, r.removed); assertEquals(2000L, r.removedBytes)
    }

    @Test fun freshUnheldKeptOldUploadCopiesAndExportsRemoved() {
        val fresh = file("upload_1.tmp", ageMs = day / 2)
        val old = listOf("upload_2.tmp", "dm_upload_3.tmp", "divine_trim_4.mp4", "backup55.zip").map { file(it, 2 * day) }
        val export = file("haven_media_1.zip", 2 * day, bytes = 500, dir = File(tmp.root, "exports"))
        val r = CacheSweep.sweep(tmp.root, now, isHeld = { false })
        assertTrue(fresh.exists())
        old.forEach { assertFalse(it.name, it.exists()) }
        assertFalse(export.exists())
        assertEquals(5, r.removed)
    }

    @Test fun cacheFoldersForeignNamesAndSymlinksNeverTouched() {
        val kept = listOf(
            file("abc", 9 * day, dir = File(tmp.root, "media_cache")),
            file("t.jpg", 9 * day, dir = File(tmp.root, "thumbnails")),
            file("x", 9 * day, dir = File(tmp.root, "video-cache")),
            file("picked_cover_1.img", 9 * day),
            file("something_else.bin", 9 * day),
        )
        val target = file("keep.bin", 9 * day, dir = File(tmp.root, "media_cache"))
        val link = File(tmp.root, "upload_link.tmp").toPath()
        Files.createSymbolicLink(link, target.toPath())
        CacheSweep.sweep(tmp.root, now + day, isHeld = { false })
        kept.forEach { assertTrue(it.path, it.exists()) }
        assertTrue(Files.isSymbolicLink(link)); assertTrue(target.exists())
    }

    @Test fun clearExportsOnlyEmptiesExports() {
        val export = file("haven_backup_1.zip", 0, dir = File(tmp.root, "exports"))
        val upload = file("upload_1.tmp", 0)
        CacheSweep.clearExports(tmp.root)
        assertFalse(export.exists()); assertTrue(upload.exists())
    }
}
