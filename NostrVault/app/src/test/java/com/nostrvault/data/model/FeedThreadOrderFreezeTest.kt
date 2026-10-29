package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.Date

class FeedThreadOrderFreezeTest {

    private fun note(id: String, seconds: Long, parent: String? = null): FeedNote = FeedNote(
        id = id,
        pubkey = "alice",
        content = "",
        createdAt = Date(seconds * 1000),
        tags = if (parent != null) listOf(listOf("e", parent, "", "root")) else emptyList(),
        kind = 1,
        repostedBy = null,
        isReply = parent != null,
        replyToPubkey = null,
        parentEventId = parent,
        mediaURLs = emptyList(),
        linkURLs = emptyList(),
        quotedEventIds = emptyList(),
        repostedEventId = null,
    )

    private fun threads(notes: List<FeedNote>) =
        FeedThreadGrouping.build(notes.sortedByDescending { it.createdAt }) { null }

    private fun roots(list: List<FeedThread>) = list.map { it.rootId }

    private val base = listOf(note("a", 300), note("b", 200), note("c", 100))

    @Test
    fun firstPassKeepsTheBuiltOrder() {
        assertEquals(listOf("a", "b", "c"), roots(FeedThreadOrderFreeze().apply(threads(base))))
    }

    @Test
    fun aReplyStaysInItsCard() {
        val freeze = FeedThreadOrderFreeze()
        freeze.apply(threads(base))
        val after = freeze.apply(threads(base + note("r", 400, parent = "c")))
        assertEquals(listOf("a", "b", "c"), roots(after))
        assertEquals(listOf("c", "r"), after.last().entries.map { it.id })
    }

    @Test
    fun resortLetsTheRepliedCardRise() {
        val freeze = FeedThreadOrderFreeze()
        freeze.apply(threads(base))
        val replied = threads(base + note("r", 400, parent = "c"))
        freeze.apply(replied)
        freeze.resort()
        assertEquals(listOf("c", "a", "b"), roots(freeze.apply(replied)))
    }

    @Test
    fun newConversationsSlotInByActivity() {
        val freeze = FeedThreadOrderFreeze()
        freeze.apply(threads(base))
        // A newer post goes above, an older page below, and a reply to a
        // frozen card still doesn't move it.
        val after = freeze.apply(threads(base + note("new", 500) + note("old", 50) + note("r", 400, parent = "c")))
        assertEquals(listOf("new", "a", "b", "c", "old"), roots(after))
    }

    @Test
    fun aCardSeenOnceKeepsItsFirstKey() {
        val freeze = FeedThreadOrderFreeze()
        freeze.apply(threads(base))
        freeze.apply(threads(base + note("new", 250)))
        val after = freeze.apply(threads(base + note("new", 250) + note("r", 600, parent = "new")))
        assertEquals(listOf("a", "new", "b", "c"), roots(after))
    }

    @Test
    fun droppedCardsDoNotHoldKeys() {
        val freeze = FeedThreadOrderFreeze()
        freeze.apply(threads(base))
        freeze.apply(threads(base.dropLast(1)))
        // "c" came back after leaving: it slots in by its activity again.
        val after = freeze.apply(threads(base + note("r", 400, parent = "c")))
        assertEquals(listOf("c", "a", "b"), roots(after))
    }
}
