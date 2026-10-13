package com.nostrvault.ui.screens.dm

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** A pasted photo's copy keeps its type in its file name, for the Blossom upload. */
class DMPastedImageTest {

    @Test
    fun aPhotoTypeIsSavedUnderItsExtension() {
        assertEquals("jpg", DMPastedImage.extensionFor("image/jpeg"))
        assertEquals("jpg", DMPastedImage.extensionFor("image/jpg"))
        assertEquals("png", DMPastedImage.extensionFor("IMAGE/PNG"))
        assertEquals("gif", DMPastedImage.extensionFor("image/gif"))
        assertEquals("webp", DMPastedImage.extensionFor("image/webp"))
    }

    @Test
    fun anythingButAPhotoIsRefused() {
        assertNull(DMPastedImage.extensionFor(null))
        assertNull(DMPastedImage.extensionFor("text/plain"))
        assertNull(DMPastedImage.extensionFor("video/mp4"))
        assertNull(DMPastedImage.extensionFor("image/svg+xml"))
    }

    @Test
    fun theTypeComesBackFromTheFileName() {
        assertEquals("image/jpeg", DMPastedImage.mimeTypeFor("paste_123.jpg"))
        assertEquals("image/gif", DMPastedImage.mimeTypeFor("paste_123.GIF"))
        assertNull(DMPastedImage.mimeTypeFor("paste_123"))
        assertNull(DMPastedImage.mimeTypeFor("paste_123.txt"))
    }

    @Test
    fun everySavedTypeRoundTrips() {
        for (type in listOf("image/jpeg", "image/png", "image/gif", "image/webp", "image/heic", "image/heif", "image/avif")) {
            val ext = DMPastedImage.extensionFor(type)!!
            assertEquals(type, DMPastedImage.mimeTypeFor("paste_1.$ext"))
        }
    }
}
