package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A repost that only points at the original (empty content plus an `e` tag)
 * is valid NIP-18. The empty-content spam rule used to drop it (iOS #227).
 */
class BareRepostTest {

    private val reposter = "a".repeat(64)
    private val author = "b".repeat(64)
    private val originalId = "c".repeat(64)

    private fun repost(content: String, tags: List<List<String>> = listOf(listOf("e", originalId), listOf("p", author))) =
        FeedNote.fromEvent("d".repeat(64), reposter, content, tags, 1_700_000_000L, 6)

    @Test fun `a bare repost is not noise`() {
        val note = repost("")
        assertTrue(note.isBareRepost)
        assertFalse(note.isNoise)
    }

    @Test fun `empty content without an e tag is still noise`() {
        assertTrue(repost("", tags = emptyList()).isNoise)
        assertTrue(FeedNote.fromEvent(originalId, author, "", emptyList(), 1_600_000_000L, 1).isNoise)
    }

    @Test fun `a bare repost draws its original credited to the reposter`() {
        val original = FeedNote.fromEvent(
            originalId, author, "look https://example.com/a.jpg", listOf(listOf("t", "x")), 1_600_000_000L, 1,
        )
        val bare = repost("")
        val shown = bare.withRepostedOriginal(original)
        assertEquals(bare.id, shown.id)
        assertEquals(bare.createdAt, shown.createdAt)
        assertEquals(author, shown.pubkey)
        assertEquals(reposter, shown.repostedBy)
        assertEquals(original.content, shown.content)
        assertEquals(original.mediaURLs, shown.mediaURLs)
        assertEquals(1_600_000_000_000L, shown.postedAt.time)
        // Likes, zaps and replies still go to the original.
        assertEquals(originalId, shown.effectiveEventId)
        assertFalse(shown.isNoise)
    }
}
