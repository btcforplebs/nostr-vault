package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A repost of an article or a poll is drawn as that kind, not as raw text:
 * the row keeps kind 6 (engagement targets the original) and carries the
 * original's kind for display.
 */
class RepostKindTest {

    private val reposter = "a".repeat(64)
    private val author = "b".repeat(64)
    private val originalId = "c".repeat(64)
    private val repostId = "d".repeat(64)

    private val pollTags = listOf(
        listOf("option", "o1", "Yes"),
        listOf("option", "o2", "No"),
        listOf("polltype", "singlechoice"),
    )

    @Test fun `a bare repost of a poll draws the poll and votes on the original`() {
        val original = FeedNote.fromEvent(originalId, author, "Ship it?", pollTags, 1_600_000_000L, NIP88Poll.KIND)
        val bare = FeedNote.fromEvent(repostId, reposter, "", listOf(listOf("e", originalId), listOf("p", author)), 1_700_000_000L, 6)
        val shown = bare.withRepostedOriginal(original)
        assertEquals(6, shown.kind)
        assertEquals(NIP88Poll.KIND, shown.displayKind)
        val poll = shown.poll
        assertNotNull(poll)
        assertEquals(originalId, poll!!.id)
        assertEquals(2, poll.options.size)
        assertEquals(NIP88Poll.KIND, shown.effectiveKind)
    }

    @Test fun `an embedded repost of an article keeps the article kind`() {
        val inner = """{"id":"$originalId","pubkey":"$author","created_at":1600000000,"kind":30023,""" +
            """"tags":[["d","x"],["title","Hello"]],"content":"# Body","sig":""}"""
        val note = FeedNote(
            id = repostId, pubkey = reposter, content = inner,
            createdAt = java.util.Date(1_700_000_000_000L),
            tags = listOf(listOf("e", originalId), listOf("p", author)), kind = 6,
        )
        assertEquals(ArticleMeta.KIND, note.displayKind)
        assertEquals(author, note.pubkey)
        assertEquals(originalId, note.effectiveEventId)
    }

    @Test fun `a plain note and an unresolved repost are unchanged`() {
        val plain = FeedNote.fromEvent(originalId, author, "hi", emptyList(), 1_600_000_000L, 1)
        assertEquals(1, plain.displayKind)
        val bare = FeedNote.fromEvent(repostId, reposter, "", listOf(listOf("e", originalId)), 1_700_000_000L, 6)
        assertEquals(6, bare.displayKind)
        assertTrue(bare.isBareRepost)
        assertEquals(1, bare.effectiveKind)
    }
}
