package com.nostrvault.service

import com.nostrvault.data.model.FeedNote
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** iOS #302 on Android: a parent already in the feed is found by its own id. */
class FeedNoteWithOwnIdTest {
    private val original = FeedNote.fromEvent("x".repeat(64), "a".repeat(64), "hello", emptyList(), 1_000L, 1)
    private val repost = FeedNote.fromEvent(
        "r".repeat(64), "b".repeat(64), "",
        listOf(listOf("e", original.id), listOf("p", original.pubkey)), 2_000L, 6,
    )

    /** The feed's real index. */
    private fun index(notes: List<FeedNote>): Map<String, FeedNote> = buildNoteIndex(notes)

    @Test
    fun aNewerRepostAboveItDoesNotHideTheOriginal() {
        val feed = listOf(repost, original)
        // Own ids are filed first, so the original keeps its own key...
        assertEquals(original.id, index(feed)[original.id]?.id)
        // ...and is found without a scan of the feed.
        assertEquals(original, feedNoteWithOwnId(index(feed), feed, original.id))
    }

    @Test
    fun aRepostAloneIsStillFoundUnderTheOriginalIdByTheIndex() {
        // findNote resolves a thread ancestor through the repost that carries it.
        assertEquals(repost, index(listOf(repost))[original.id])
    }

    @Test
    fun aRepostAloneIsNeverTakenForTheOriginal() {
        val feed = listOf(repost)
        assertNull(feedNoteWithOwnId(index(feed), feed, original.id))
    }

    @Test
    fun aDirectHitIsReturned() {
        val feed = listOf(original)
        assertEquals(original, feedNoteWithOwnId(index(feed), feed, original.id))
    }

    @Test
    fun anIdNotInTheFeedIsNull() {
        assertNull(feedNoteWithOwnId(index(listOf(original)), listOf(original), "z".repeat(64)))
    }
}
