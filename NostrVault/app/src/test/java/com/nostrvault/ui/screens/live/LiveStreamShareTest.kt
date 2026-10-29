package com.nostrvault.ui.screens.live

import org.junit.Assert.assertEquals
import org.junit.Test

/** "Share as a note": what the composer starts with, so other apps show the picture and a playable video. */
class LiveStreamShareTest {
    @Test fun theNoteCarriesTitlePictureStreamAndAddress() {
        assertEquals(
            "Live now: Late night jam\nhttps://x/cover.jpg\nhttps://x/live.m3u8\nnostr:naddr1abc",
            LiveStreamShare.noteText("  Late night jam ", "https://x/cover.jpg", "https://x/live.m3u8", "naddr1abc"),
        )
    }

    @Test fun missingPartsAreLeftOutNotPrintedAsNull() {
        assertEquals("Live now: a stream\nhttps://x/live.m3u8", LiveStreamShare.noteText(null, null, "https://x/live.m3u8", null))
        assertEquals("Live now: a stream", LiveStreamShare.noteText("  ", null, null, null))
    }
}

/** A profile route is built only from a real key (Tron, #1308). */
class LiveStreamLeaveTest {
    @Test fun onlyLowercaseHex64IsAPubkey() {
        org.junit.Assert.assertTrue(LiveStreamLeave.isPubkey("a".repeat(64)))
        org.junit.Assert.assertFalse(LiveStreamLeave.isPubkey("a/b"))
        org.junit.Assert.assertFalse(LiveStreamLeave.isPubkey("A".repeat(64)))
        org.junit.Assert.assertFalse(LiveStreamLeave.isPubkey("a".repeat(63)))
    }
}
