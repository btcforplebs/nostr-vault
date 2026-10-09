package com.nostrvault.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A pick from the composer's relay picker publishes an `imeta`; its `m` must
 * be a real MIME type or absent, never the gallery's coarse "image"/"video".
 */
class ComposeRelayPickTest {
    @Test fun serverMimeWins() {
        assertEquals("image/png", blobMimeType("image/png", "x.jpg"))
    }

    @Test fun coarseKindFallsBackToExtension() {
        assertEquals("image/jpeg", blobMimeType("image", "https://m.example/abc.JPG"))
        assertEquals("video/quicktime", blobMimeType(null, "/data/blossom/abc.mov"))
    }

    @Test fun unknownIsNull() {
        assertNull(blobMimeType("image", "https://m.example/" + "a".repeat(64)))
        assertNull(blobMimeType("image/*", null))
    }

    private fun item(mime: String?, url: String = "https://m.example/x") = BlossomMediaItem(
        sha256 = "a".repeat(64), displayUrl = url, localFile = null, mimeType = mime,
        size = null, uploaded = null, lastModified = null, isLocal = false,
    )

    @Test fun pickerFilterIsTheMediaTabFilter() {
        val gif = item("image/gif")
        val png = item("image/png")
        val mp4 = item("video/mp4")
        assertTrue(MediaTypeFilter.GIF.matches(gif))
        assertFalse(MediaTypeFilter.PHOTO.matches(gif))
        assertTrue(MediaTypeFilter.PHOTO.matches(png))
        assertTrue(MediaTypeFilter.VIDEO.matches(mp4))
        assertFalse(MediaTypeFilter.VIDEO.matches(png))
        assertTrue(MediaTypeFilter.ALL.matches(mp4))
    }
}

/** The relay picker lists audio too (iOS relayBlossomMedia); it must post as audio, not a .jpg. */
class ComposeRelayPickAudioTest {
    private fun item(mime: String?, url: String) = BlossomMediaItem(
        sha256 = "b".repeat(64), displayUrl = url, localFile = null, mimeType = mime,
        size = null, uploaded = null, lastModified = null, isLocal = false,
    )

    @Test fun audioExtensionsHaveRealTypes() {
        assertEquals("audio/mpeg", blobMimeType(null, "/data/blossom/abc.mp3"))
        assertEquals("audio/mp4", blobMimeType("audio", "https://m.example/abc.M4A"))
        assertEquals("audio/ogg", blobMimeType(null, "abc.ogg?x=1"))
    }

    @Test fun bareAudioLinkGetsAnAudioExtension() {
        val bare = item("audio/mpeg", "https://m.example/" + "b".repeat(64))
        assertEquals("https://m.example/" + "b".repeat(64) + ".mp3", blossomShareLink(bare))
        assertTrue(bare.isAudio)
        assertFalse(bare.isImage)
    }
}
