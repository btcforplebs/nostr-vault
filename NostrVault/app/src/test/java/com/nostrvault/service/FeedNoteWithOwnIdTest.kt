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

    /** The feed's index, built as noteIndex() does: id, then effectiveEventId, first wins. */
    private fun index(notes: List<FeedNote>): Map<String, FeedNote> {
        val map = HashMap<String, FeedNote>()
        for (n in notes) {
            map.putIfAbsent(n.id, n)
            map.putIfAbsent(n.effectiveEventId, n)
        }
        return map
    }

    @Test
    fun aNewerRepostAboveItDoesNotHideTheOriginal() {
        val feed = listOf(repost, original)
        // The repost claims the original's id in the index...
        assertEquals(repost.id, index(feed)[original.id]?.id)
        // ...and the original is still found.
        assertEquals(original, feedNoteWithOwnId(index(feed), feed, original.id))
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
