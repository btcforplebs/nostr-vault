package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Reels pagination rule: one cursor per stream, each the newest of the relays' oldest events. */
class ReelCursorsTest {

    @Test
    fun `first page asks both streams with no cursor`() {
        val filters = ReelCursors().filters(authors = listOf("a", "b"))
        assertEquals(
            listOf(
                """{"kinds":[21,22,34235,34236],"limit":100,"authors":["a","b"]}""",
                """{"kinds":[1],"limit":300,"authors":["a","b"]}""",
            ),
            filters,
        )
    }

    @Test
    fun `global scope sends no authors`() {
        ReelCursors().filters(authors = null).forEach { assertFalse(it.contains("authors")) }
    }

    @Test
    fun `cursor is the newest of the relays' oldest events, per stream`() {
        // Relay 0 is dense (its page stopped at 900); relay 1 is sparse and
        // reached back to 100. Resuming at 100 would skip 101..899 on relay 0.
        val next = ReelCursors().afterPage(
            listOf(
                mapOf(ReelStream.NOTE to 900L, ReelStream.VIDEO to 50L),
                mapOf(ReelStream.NOTE to 100L, ReelStream.VIDEO to 700L),
            ),
            producedReels = true,
        )
        assertEquals(899L, next.until[ReelStream.NOTE])
        assertEquals(699L, next.until[ReelStream.VIDEO])
        assertEquals(
            listOf(
                """{"kinds":[21,22,34235,34236],"limit":100,"until":699}""",
                """{"kinds":[1],"limit":300,"until":899}""",
            ),
            next.filters(authors = null),
        )
    }

    @Test
    fun `a stream no relay returned anything for stops paging, the other carries on`() {
        val next = ReelCursors().afterPage(
            listOf(mapOf(ReelStream.NOTE to 500L), emptyMap()),
            producedReels = true,
        )
        assertEquals(setOf(ReelStream.VIDEO), next.exhausted)
        assertEquals(listOf(ReelStream.NOTE), next.activeStreams)
        assertEquals(listOf("""{"kinds":[1],"limit":300,"until":499}"""), next.filters(null))
        assertFalse(next.reachedEnd)

        // An exhausted stream keeps its last cursor and is not revived.
        val after = next.afterPage(listOf(mapOf(ReelStream.VIDEO to 10L)), producedReels = true)
        assertEquals(setOf(ReelStream.VIDEO, ReelStream.NOTE), after.exhausted)
        assertTrue(after.reachedEnd)
        assertTrue(after.filters(null).isEmpty())
    }

    @Test
    fun `a run of pages with no video ends paging, and one reel resets it`() {
        val page = listOf(mapOf(ReelStream.NOTE to 1_000L, ReelStream.VIDEO to 1_000L))
        var cursors = ReelCursors()
        repeat(ReelCursors.MAX_EMPTY_PAGES - 1) { cursors = cursors.afterPage(page, producedReels = false) }
        assertFalse(cursors.reachedEnd)
        assertEquals(0, cursors.afterPage(page, producedReels = true).emptyPages)
        assertTrue(cursors.afterPage(page, producedReels = false).reachedEnd)
    }

    @Test
    fun `paging continues on its own only near the end`() {
        assertTrue(ReelCursors.shouldContinue(reelCount = 0, shownIndex = 0, reachedEnd = false))
        assertTrue(ReelCursors.shouldContinue(reelCount = 10, shownIndex = 7, reachedEnd = false))
        assertFalse(ReelCursors.shouldContinue(reelCount = 10, shownIndex = 6, reachedEnd = false))
        assertFalse(ReelCursors.shouldContinue(reelCount = 0, shownIndex = 0, reachedEnd = true))
        assertFalse(ReelCursors.shouldContinue(reelCount = 10, shownIndex = 9, reachedEnd = true))
    }
}
