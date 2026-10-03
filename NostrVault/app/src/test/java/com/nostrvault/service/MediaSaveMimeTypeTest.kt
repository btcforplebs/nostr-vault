package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Saving feed media to the gallery: Blossom servers often answer
 * `application/octet-stream`, so the gallery type comes from the caller's
 * hint, then a media Content-Type, then the URL's extension.
 */
class MediaSaveMimeTypeTest {

    private val hashUrl = "https://blossom.example/" + "b".repeat(64)

    @Test
    fun `a video hint beats an octet-stream answer`() {
        assertEquals("video/mp4", MediaSaveService.resolveMimeType("video/mp4", "application/octet-stream", "$hashUrl.mp4"))
    }

    @Test
    fun `a media content type is used, without parameters`() {
        assertEquals("image/png", MediaSaveService.resolveMimeType(null, "image/png; charset=binary", hashUrl))
    }

    @Test
    fun `octet-stream falls back to the extension`() {
        assertEquals("video/quicktime", MediaSaveService.resolveMimeType(null, "application/octet-stream", "$hashUrl.MOV?x=1"))
    }

    @Test
    fun `nothing known is a photo`() {
        assertEquals("image/jpeg", MediaSaveService.resolveMimeType(null, null, hashUrl))
    }

    @Test
    fun `audio cannot go to the gallery`() {
        assertNull(MediaSaveService.resolveMimeType("audio/mpeg", "audio/mpeg", "$hashUrl.mp3"))
    }

    @Test
    fun `extensions follow the type`() {
        assertEquals("mp4", MediaSaveService.extensionForMimeType("video/mp4"))
        assertEquals("mkv", MediaSaveService.extensionForMimeType("video/x-matroska"))
        assertEquals("mp4", MediaSaveService.extensionForMimeType("video/3gpp"))
        assertEquals("webp", MediaSaveService.extensionForMimeType("image/webp"))
        assertEquals("jpg", MediaSaveService.extensionForMimeType("image/x-unknown"))
    }
}
