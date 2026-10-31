package com.nostrvault.ui.screens.live

import org.junit.Assert.assertEquals
import org.junit.Test

/** "Share as a note": "Live now: <host>" and the stream's naddr, nothing the Live card already draws. */
class LiveStreamShareTest {
    private val service = "b2".repeat(32)

    @Test fun theNoteIsTheHostAndTheAddressOnly() {
        assertEquals("Live now: The Lot Radio\n\nnostr:naddr1abc", LiveStreamShare.noteText(" The Lot Radio ", "naddr1abc"))
    }

    @Test fun missingPartsAreLeftOutNotPrintedAsNull() {
        assertEquals("Live now: Ann", LiveStreamShare.noteText("Ann", null))
        assertEquals("Live now: a stream", LiveStreamShare.noteText("  ", null))
    }

    /** No title, picture or playlist, whatever the stream carries: the title goes stale on a reused 30311. */
    @Test fun aStreamSharesItsHostNotItsTitle() {
        val stream = com.nostrvault.data.model.LiveStream.from(service, 1L, listOf(
            listOf("d", "lot-radio"), listOf("title", "Love Injection"), listOf("image", "https://x/cover.png"),
            listOf("streaming", "https://x/index.m3u8"),
        ))!!
        val text = LiveStreamShare.noteText(stream, "The Lot Radio")
        assertEquals("Live now: The Lot Radio\n\nnostr:${LiveStreamShare.naddr(stream)}", text)
        org.junit.Assert.assertFalse(text.contains("Love Injection") || text.contains("http"))
    }

    @Test fun aLiveNaddrInTheTextGetsOneQTag() {
        val live = com.nostrvault.relay.HavenBridge.encodeNaddr("lot-radio", service, 30311)!!
        val article = com.nostrvault.relay.HavenBridge.encodeNaddr("post", service, 30023)!!
        assertEquals(
            listOf(listOf("q", "30311:$service:lot-radio", "")),
            LiveStreamShare.quoteTags("Live now: Ann\n\nnostr:$live nostr:$live nostr:$article"),
        )
        assertEquals(emptyList<List<String>>(), LiveStreamShare.quoteTags("no quotes here"))
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
