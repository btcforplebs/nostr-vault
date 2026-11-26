package com.nostrvault.service.media

import com.nostrvault.service.media.ImageCompressor.Quality
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** Settings > Media & Cache > Upload Quality (Logen 2026-11-26). */
class UploadQualityTest {
    @Test fun `default and unknown settings are Standard`() {
        assertEquals(Quality.STANDARD, UploadQuality.from(com.nostrvault.relay.HavenConfig().uploadQuality))
        assertEquals(Quality.STANDARD, UploadQuality.from("standard"))
        assertEquals(Quality.STANDARD, UploadQuality.from(""))
        assertEquals(Quality.STANDARD, UploadQuality.from("ORIGINAL"))
        assertEquals("Standard", UploadQuality.label(""))
    }

    @Test fun `original setting is Original`() {
        assertEquals(Quality.ORIGINAL, UploadQuality.from("original"))
        assertEquals("Original", UploadQuality.label("original"))
    }

    private fun bytes(size: Int) = ByteArray(size) { (it * 31 + 7).toByte() }

    /** Original never opens the file: the same file with the same bytes comes back, photo or video. */
    @Test fun `Original passes photo bytes through`() {
        val dir = Files.createTempDirectory("uq").toFile()
        try {
            val want = bytes(3_000_000)
            for (mime in listOf("image/jpeg", "image/heic", "image/png", "image/webp")) {
                val src = File(dir, "src").apply { writeBytes(want) }
                val out = ImageCompressor.replacing(src, mime, Quality.ORIGINAL, dir)
                assertSame(src, out.file)
                assertEquals(mime, out.mimeType)
                assertArrayEquals(want, out.file.readBytes())
                assertEquals(listOf("src"), dir.list()!!.toList())
            }
        } finally { dir.deleteRecursively() }
    }

    @Test fun `Original passes video bytes through`() {
        val dir = Files.createTempDirectory("uq").toFile()
        try {
            val want = bytes(5_000_000)
            val src = File(dir, "clip.mov").apply { writeBytes(want) }
            // compress() returns this before it reads anything or touches the Context.
            val out = VideoCompressor.untouched(src, "video/quicktime", Quality.ORIGINAL)!!
            assertSame(src, out.file)
            assertEquals("video/quicktime", out.mimeType)
            assertArrayEquals(want, out.file.readBytes())
            assertEquals(null, VideoCompressor.untouched(src, "video/quicktime", Quality.STANDARD))
        } finally { dir.deleteRecursively() }
    }
}
