package com.nostrvault.ui.components

import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.QuoteRef
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.HavenQuoteDecoder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** A note quoting a live stream shows heading + Live card only (Logen 10-31, Lot Radio share). */
class LiveNoteLinksTest {
    private val service = "b2".repeat(32)
    private val liveNaddr = HavenBridge.encodeNaddr("lot-radio", service, 30311)!!
    private val liveKey = QuoteRef.format(QuoteRef.Coordinate(30311, service, "lot-radio"))
    private val cover = "https://x.example/cover.png"
    private val playlist = "https://livepeercdn.studio/hls/abc/index.m3u8"

    /** Logen's real note shape: heading, cover, playlist, naddr, each on its own line. */
    private val logensNote = "Live now: The Lot Radio: Love Injection\n$cover\n$playlist\nnostr:$liveNaddr"

    private fun note(content: String) = FeedNote.fromEvent(id = "a".repeat(64), pubkey = "c".repeat(64), content = content,
        tags = emptyList(), createdAt = 1L, kind = 1)

    private fun stream(vararg tags: List<String>) = FeedNote.fromEvent(id = "d".repeat(64), pubkey = service, content = "",
        tags = listOf(listOf("d", "lot-radio")) + tags, createdAt = 1L, kind = 30311)

    @Test fun logensNoteEndsAsHeadingAndCardOnceTheStreamIsLoaded() {
        val n = note(logensNote)
        assertEquals(listOf(liveKey), n.quotedEventIds)
        val quoted = mapOf(liveKey to stream(listOf("image", cover), listOf("streaming", playlist)))
        val hidden = LiveNoteLinks.hidden(n.mediaURLs + n.linkURLs, n.quotedEventIds, quoted)
        assertEquals(setOf(cover, playlist), hidden)
        assertEquals("Live now: The Lot Radio: Love Injection", LiveNoteLinks.body(n.content, hidden, HavenQuoteDecoder))
        assertTrue((n.mediaURLs - hidden).isEmpty())
        assertTrue((n.cardLinkURLs - hidden).isEmpty())
    }

    /** Before the stream loads the playlist already goes; the cover waits until it is known to be the stream's. */
    @Test fun aPlaylistGoesAtOnceAndOtherPicturesStay() {
        val n = note(logensNote)
        assertEquals(setOf(playlist), LiveNoteLinks.hidden(n.mediaURLs + n.linkURLs, n.quotedEventIds, emptyMap()))
        val other = mapOf(liveKey to stream(listOf("image", "https://x.example/new-show.png")))
        assertEquals(setOf(playlist), LiveNoteLinks.hidden(n.mediaURLs + n.linkURLs, n.quotedEventIds, other))
    }

    @Test fun blankLinesAroundTheCardCloseUp() {
        val text = "Live now: Ann\n\n\n$playlist\n\nnostr:$liveNaddr\n\n\nsee you there  \n"
        assertEquals("Live now: Ann\n\nsee you there", LiveNoteLinks.body(text, setOf(playlist), HavenQuoteDecoder))
    }

    /** A note with no live quote is left exactly as written, playlist and all. */
    @Test fun aNoteWithoutALiveQuoteIsUntouched() {
        val article = HavenBridge.encodeNaddr("post", service, 30023)!!
        val text = "watch $playlist\n\n\nnostr:$article"
        val n = note(text)
        assertTrue(LiveNoteLinks.hidden(n.mediaURLs + n.linkURLs, n.quotedEventIds, emptyMap()).isEmpty())
        assertEquals(text, LiveNoteLinks.body(text, emptySet(), HavenQuoteDecoder))
    }

    /** Removing one link never eats a longer link that starts the same way. */
    @Test fun onlyWholeLinksLeave() {
        val text = "Live now: Ann\n$cover.extra\nnostr:$liveNaddr"
        assertEquals("Live now: Ann\n$cover.extra", LiveNoteLinks.body(text, setOf(cover), HavenQuoteDecoder))
    }
}
