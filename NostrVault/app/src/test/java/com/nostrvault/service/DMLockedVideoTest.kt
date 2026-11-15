package com.nostrvault.service

import com.nostrvault.ui.components.isVideoUrl
import com.nostrvault.ui.screens.dm.DMLockedVideo
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** Videos in DMs go locked like photos (kind 15, Logen 2026-11-15). */
class DMLockedVideoTest {
    private val x = "a".repeat(64)
    private fun link(mime: String) = DMFile.fileLink("https://nostr.download/$x", "1".repeat(64), "2".repeat(24), x, mime)

    @Test
    fun `a locked file may be up to 100 MB`() {
        assertEquals(100L * 1024 * 1024, DMFile.MAX_FILE)
    }

    @Test
    fun `a video over 100 MB after compressing is refused with a clear message`() {
        assertNull(DMLockedVideo.sizeError(DMFile.MAX_FILE - 16))
        val msg = DMLockedVideo.sizeError(DMFile.MAX_FILE)
        assertTrue(msg!!.contains("100 MB"))
    }

    @Test
    fun `a locked video link is a video, a locked photo link is not`() {
        assertTrue(DMFile.isVideoLink(link("video/mp4")))
        assertTrue(DMFile.isVideoLink(link("video/quicktime")))
        assertFalse(DMFile.isVideoLink(link("image/jpeg")))
        assertFalse(DMFile.isVideoLink("https://nostr.download/$x.mp4"))
        // The viewer tells videos by extension; a locked link's type is in its fragment.
        assertTrue(isVideoUrl(link("video/mp4")))
        assertFalse(isVideoUrl(link("image/png")))
    }

    @Test
    fun `the inbox line names a video`() {
        assertEquals("Video", DMFile.previewOf(link("video/mp4")))
        assertEquals("Photo", DMFile.previewOf(link("image/png")))
    }

    @Test
    fun `opening reports how much has arrived`() = runBlocking {
        val dir: File = Files.createTempDirectory("dmvideo").toFile()
        val ctx = mockk<android.content.Context> { every { cacheDir } returns dir }
        val plain = ByteArray(1000) { it.toByte() }
        val enc = DMFile.encrypt(plain)
        File(dir, "dm_files").apply { mkdirs() }.resolve(enc.x).writeBytes(enc.cipher)
        val l = DMFile.fileLink("https://files.example/${enc.x}", enc.key, enc.nonce, enc.x, "video/mp4", enc.ox)
        val seen = mutableListOf<Pair<Long, Long>>()
        DMFileLoader.open(ctx, l, onProgress = { got, total -> seen.add(got to total) })
        assertEquals(enc.cipher.size.toLong() to enc.cipher.size.toLong(), seen.last())
    }
}
