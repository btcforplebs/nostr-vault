package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/** A NIP-84 highlight shows its source as a quote and never as a thread reply. */
class FeedHighlightTest {

    private val author = "a".repeat(64)
    private val sourceAuthor = "b".repeat(64)
    private val sourceId = "c".repeat(64)
    private val highlightId = "d".repeat(64)
    private val coordinate = "30023:$sourceAuthor:my-article"

    private fun highlight(tags: List<List<String>>) =
        FeedNote.fromEvent(highlightId, author, "the passage", tags, 1_700_000_000L, FeedHighlight.KIND)

    @Test fun `an article highlight quotes the article by coordinate`() {
        val note = highlight(listOf(listOf("a", coordinate), listOf("e", sourceId), listOf("p", sourceAuthor)))
        assertEquals(listOf(QuoteRef.COORDINATE_PREFIX + coordinate), note.quotedEventIds)
        assertFalse(note.isReply)
        assertNull(note.parentEventId)
        assertNull(note.replyToPubkey)
        assertEquals(highlightId, note.threadRootId)
        assertEquals(FeedHighlight.KIND, note.displayKind)
    }

    @Test fun `a note highlight quotes the note by id`() {
        val note = highlight(listOf(listOf("e", sourceId)))
        assertEquals(listOf(sourceId), note.quotedEventIds)
        assertNull(FeedHighlight.sourceURL(note.tags))
    }

    @Test fun `a web highlight links the page and quotes nothing`() {
        val tags = listOf(listOf("r", "https://example.com/post"), listOf("comment", "  so true  "))
        val note = highlight(tags)
        assertEquals(emptyList<String>(), note.quotedEventIds)
        assertEquals("https://example.com/post", FeedHighlight.sourceURL(tags))
        assertEquals("so true", FeedHighlight.comment(tags))
        assertNull(FeedHighlight.sourceURL(listOf(listOf("r", "javascript:alert(1)"))))
        assertNull(FeedHighlight.comment(listOf(listOf("comment", " "))))
    }

    @Test fun `a repost of a highlight still quotes its source`() {
        val inner = """{"id":"$highlightId","pubkey":"$author","created_at":1600000000,"kind":9802,""" +
            """"tags":[["a","$coordinate"]],"content":"the passage","sig":""}"""
        val note = FeedNote.fromEvent("e".repeat(64), sourceAuthor, inner, listOf(listOf("e", highlightId)), 1_700_000_000L, GenericRepost.KIND)
        assertEquals(FeedHighlight.KIND, note.displayKind)
        assertEquals(listOf(QuoteRef.COORDINATE_PREFIX + coordinate), note.quotedEventIds)
    }

    @Test fun `an uncaptioned picture post is not noise`() {
        val picture = FeedNote.fromEvent(
            highlightId, author, "", listOf(listOf("imeta", "url https://example.com/a.jpg", "m image/jpeg")),
            1_700_000_000L, FeedNote.PICTURE_KIND,
        )
        assertEquals(listOf("https://example.com/a.jpg"), picture.mediaURLs)
        assertFalse(picture.isNoise)
        assert(FeedNote.fromEvent(highlightId, author, "", emptyList(), 1_700_000_000L, FeedNote.PICTURE_KIND).isNoise)
    }

    @Test fun `timelines ask for every drawn kind`() {
        for (k in listOf(1, 6, 30023, 1111, 1068, 16, 20, 9802)) assert(k in FeedNote.TIMELINE_KINDS) { "$k" }
    }
}
