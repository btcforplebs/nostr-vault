package com.nostrvault.service

import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedNote
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Global and Popular are top-level posts only, whatever the Replies switch
 * says; Following keeps obeying it. iOS FeedFilterEngine.filterFeedNotes.
 */
class FeedRepliesScopeTest {
    private val friend = "f".repeat(64)

    private val post = FeedNote.fromEvent(
        id = "1".repeat(64), pubkey = friend, content = "A post", tags = emptyList(),
        createdAt = 1_790_000_000, kind = 1,
    )
    private val reply = FeedNote.fromEvent(
        id = "2".repeat(64), pubkey = friend, content = "A reply",
        tags = listOf(listOf("e", "1".repeat(64), "", "root")),
        createdAt = 1_790_000_001, kind = 1,
    )

    private fun shown(mode: FeedMode, showReplies: Boolean) = FeedFilterEngine.filterFeedNotes(
        notes = listOf(post, reply), mode = mode, blocked = emptySet(), showReposts = true,
        showReplies = showReplies, followedPubkeys = setOf(friend), wotPubkeys = setOf(friend),
    ).map { it.content }.toSet()

    @Test fun `global drops replies even with replies on`() {
        assertEquals(setOf("A post"), shown(FeedMode.GLOBAL, showReplies = true))
    }

    @Test fun `popular drops replies even with replies on`() {
        assertEquals(setOf("A post"), shown(FeedMode.POPULAR, showReplies = true))
    }

    @Test fun `following still obeys the replies switch`() {
        assertEquals(setOf("A post", "A reply"), shown(FeedMode.FOLLOWING, showReplies = true))
        assertEquals(setOf("A post"), shown(FeedMode.FOLLOWING, showReplies = false))
    }
}
