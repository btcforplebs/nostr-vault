package com.nostrvault.ui.screens

import com.nostrvault.ui.screens.MediaTypeFilter.*
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Media tab's multi-select type filter, ported from iOS MediaTypeFilter. */
class MediaTypeSelectionTest {

    private fun item(mime: String?, url: String = "https://m.example/x") = BlossomMediaItem(
        sha256 = "a".repeat(64), displayUrl = url, localFile = null, mimeType = mime,
        size = null, uploaded = null, lastModified = null, isLocal = false,
    )

    @Test fun tapFromEverythingNarrowsToThatType() {
        assertEquals(setOf(VIDEO), MediaTypeSelection.tap(MediaTypeSelection.ALL, VIDEO))
    }

    @Test fun tapAddsAndRemovesButKeepsTheLastOne() {
        val two = MediaTypeSelection.tap(setOf(PHOTO), GIF)
        assertEquals(setOf(PHOTO, GIF), two)
        assertEquals(setOf(GIF), MediaTypeSelection.tap(two, PHOTO))
        assertEquals(setOf(GIF), MediaTypeSelection.tap(setOf(GIF), GIF))
    }

    @Test fun allSelectsEverythingAndIsOnlyOnThen() {
        assertEquals(MediaTypeSelection.ALL, MediaTypeSelection.tap(setOf(PHOTO), ALL))
        assertTrue(MediaTypeSelection.isOn(MediaTypeSelection.ALL, ALL))
        assertFalse(MediaTypeSelection.isOn(setOf(PHOTO, VIDEO, GIF), ALL))
        assertTrue(MediaTypeSelection.isOn(setOf(PHOTO, VIDEO), VIDEO))
    }

    @Test fun storedAsCsvAndEmptyMeansEverything() {
        assertEquals("photo,gif", MediaTypeSelection.toKey(setOf(GIF, PHOTO)))
        assertEquals(setOf(PHOTO, GIF), MediaTypeSelection.fromKey("photo,gif"))
        assertEquals(MediaTypeSelection.ALL, MediaTypeSelection.fromKey(null))
        assertEquals(MediaTypeSelection.ALL, MediaTypeSelection.fromKey(""))
        assertEquals(MediaTypeSelection.ALL, MediaTypeSelection.fromKey("bogus"))
    }

    @Test fun eachItemHasOneCategoryAndAudioHasItsOwn() {
        assertEquals(GIF, MediaTypeSelection.category(item("image/gif")))
        assertEquals(PHOTO, MediaTypeSelection.category(item("image/png")))
        assertEquals(VIDEO, MediaTypeSelection.category(item("video/mp4")))
        assertEquals(AUDIO, MediaTypeSelection.category(item("audio/mpeg")))
        assertEquals(OTHER, MediaTypeSelection.category(item("application/pdf", "https://m.example/a.pdf")))
        assertTrue(MediaTypeSelection.matches(setOf(AUDIO), item("audio/ogg")))
        assertFalse(MediaTypeSelection.matches(setOf(OTHER), item("audio/ogg")))
        assertTrue(MediaTypeSelection.matches(setOf(PHOTO, VIDEO), item("video/mp4")))
        assertFalse(MediaTypeSelection.matches(setOf(PHOTO, VIDEO), item("audio/mpeg")))
    }

    @Test fun audioIsKnownByExtensionWhenTheTypeIsVague() {
        assertTrue(item("audio/mpeg").isAudio)
        assertTrue(item("application/octet-stream", "https://m.example/song.m4a").isAudio)
        assertFalse(item("image/png", "https://m.example/cover.mp3").isAudio)
        assertFalse(item(null, "https://m.example/clip.mp4").isAudio)
    }

    @Test fun audioChipMatchesEveryAudioEnding() {
        for (ext in listOf("mp3", "m4a", "aac", "wav", "ogg", "opus", "flac", "MP3")) {
            val it = item("application/octet-stream", "https://m.example/song.$ext")
            assertEquals(ext, AUDIO, MediaTypeSelection.category(it))
            assertTrue(ext, AUDIO.matches(it))
            assertFalse(ext, OTHER.matches(it))
        }
        assertEquals(AUDIO, MediaTypeSelection.category(item(null, "https://m.example/song.flac")))
    }

    @Test fun audioSitsAfterGifAndOldEverythingStillMeansEverything() {
        assertEquals(listOf(PHOTO, VIDEO, GIF, AUDIO, OTHER), MediaTypeSelection.TYPES)
        assertEquals(MediaTypeSelection.ALL, MediaTypeSelection.fromKey("photo,video,gif,other"))
        assertEquals(setOf(AUDIO), MediaTypeSelection.fromKey("audio"))
        assertEquals("photo,video,gif,audio,other", MediaTypeSelection.toKey(MediaTypeSelection.ALL))
    }
}
