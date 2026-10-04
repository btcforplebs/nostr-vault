package com.nostrvault.data.model

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Test

/** A repost row shows when the original was written, not when it was reposted. */
class RepostPostedAtTest {

    private val reposter = "a".repeat(64)
    private val author = "b".repeat(64)
    private val originalId = "c".repeat(64)
    private val written = 1_600_000_000L
    private val reposted = 1_700_000_000L

    private val embedded =
        """{"id":"$originalId","pubkey":"$author","created_at":$written,"kind":1,"tags":[],"content":"An old post worth sharing","sig":""}"""

    private fun repost(content: String) = FeedNote.fromEvent(
        "d".repeat(64), reposter, content, listOf(listOf("e", originalId), listOf("p", author)), reposted, 6,
    )

    @Test fun `embedded repost shows the original's time and keeps its own for ordering`() {
        val note = repost(embedded)
        assertEquals(author, note.pubkey)
        assertEquals(written * 1000, note.postedAt.time)
        assertEquals(reposted * 1000, note.createdAt.time)
    }

    @Test fun `bare repost and plain notes fall back to createdAt`() {
        assertEquals(reposted * 1000, repost("").postedAt.time)
        val plain = FeedNote.fromEvent(originalId, author, "hello", emptyList(), written, 1)
        assertEquals(written * 1000, plain.postedAt.time)
    }

    @Test fun `original time survives the feed snapshot`() {
        val note = repost(embedded)
        val json = Json { ignoreUnknownKeys = true }
        val back = json.decodeFromString<FeedNote>(json.encodeToString(note))
        assertEquals(written * 1000, back.postedAt.time)
    }
}
