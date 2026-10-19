package com.nostrvault.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HeicToJpegTest {
    @Test fun heicAndHeifAreConverted() {
        assertTrue(isHeic("image/heic"))
        assertTrue(isHeic("image/HEIF"))
        assertTrue(isHeic("image/heic-sequence"))
        assertTrue(isHeic("image/heic; charset=binary"))
    }

    @Test fun everythingElseKeepsItsBytes() {
        assertFalse(isHeic("image/jpeg"))
        assertFalse(isHeic("image/png"))
        assertFalse(isHeic("image/avif"))
        assertFalse(isHeic("video/mp4"))
        assertFalse(isHeic("application/octet-stream"))
    }

    @Test fun convertedMimeIsJpeg() = assertEquals("image/jpeg", JPEG_MIME)
}
