package com.nostrvault.data.gif

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class GifCacheTest {
    @get:Rule val tmp = TemporaryFolder()

    @Test fun newFilesAreRecognised() {
        val dir = tmp.newFolder("cache")
        val gif = GifCache.newFile(dir, "image/gif").apply { writeText("x") }
        val webp = GifCache.newFile(dir, "image/webp").apply { writeText("x") }
        assertTrue(gif.name.endsWith(".gif"))
        assertTrue(webp.name.endsWith(".webp"))
        assertTrue(GifCache.isGifCacheFile(gif))
        assertTrue(GifCache.isGifCacheFile(webp))
    }

    /** The sweep takes only this app's GIF copies, never other cache files. */
    @Test fun sweepTakesOnlyGifCopies() {
        val dir = tmp.newFolder("cache")
        val gif = GifCache.newFile(dir, "image/gif").apply { writeText("x") }
        val webp = GifCache.newFile(dir, "image/webp").apply { writeText("x") }
        val upload = File(dir, "upload_123.tmp").apply { writeText("x") }
        val other = File(dir, "gif-notes.txt").apply { writeText("x") }
        val image = File(dir, "photo.gif").apply { writeText("x") }
        File(dir, "gif-folder.gif").mkdir()

        assertEquals(2, GifCache.sweep(dir))
        assertFalse(gif.exists())
        assertFalse(webp.exists())
        assertTrue(upload.exists())
        assertTrue(other.exists())
        assertTrue(image.exists())
        assertTrue(File(dir, "gif-folder.gif").isDirectory)
    }

    @Test fun deleteIfOwnedOnlyInTheCacheDir() {
        val dir = tmp.newFolder("cache")
        val elsewhere = tmp.newFolder("elsewhere")
        val mine = GifCache.newFile(dir, "image/gif").apply { writeText("x") }
        val theirs = GifCache.newFile(elsewhere, "image/gif").apply { writeText("x") }
        val photo = File(dir, "photo.gif").apply { writeText("x") }

        assertTrue(GifCache.deleteIfOwned(mine, dir))
        assertFalse(mine.exists())
        assertFalse(GifCache.deleteIfOwned(theirs, dir))
        assertTrue(theirs.exists())
        assertFalse(GifCache.deleteIfOwned(photo, dir))
        assertTrue(photo.exists())
    }

    @Test fun sweepOfMissingDirIsZero() {
        assertEquals(0, GifCache.sweep(File(tmp.root, "nope")))
    }
}
