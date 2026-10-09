package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Reels pagination rule: the cursor is the newest of the relays' oldest events. */
class ReelCursorsTest {

    @Test
    fun `first page asks for diVine videos with no cursor`() {
        assertEquals(
            listOf("""{"kinds":[34236],"limit":100,"authors":["a","b"]}"""),
            ReelCursors().filters(authors = listOf("a", "b")),
        )
    }

    @Test
    fun `global scope sends no authors`() {
        ReelCursors().filters(authors = null).forEach { assertFalse(it.contains("authors")) }
    }

    @Test
    fun `cursor is the newest of the relays' oldest events`() {
        // Relay 0 is dense (its page stopped at 900); relay 1 is sparse and
        // reached back to 100. Resuming at 100 would skip 101..899 on relay 0.
        val next = ReelCursors().afterPage(
            listOf(mapOf(ReelStream.VIDEO to 900L), mapOf(ReelStream.VIDEO to 100L)),
            producedReels = true,
        )
        assertEquals(899L, next.until[ReelStream.VIDEO])
        assertEquals(listOf("""{"kinds":[34236],"limit":100,"until":899}"""), next.filters(authors = null))
    }

    @Test
    fun `a page no relay returned anything for ends paging`() {
        val next = ReelCursors().afterPage(listOf(emptyMap(), emptyMap()), producedReels = false)
        assertEquals(setOf(ReelStream.VIDEO), next.exhausted)
        assertTrue(next.reachedEnd)
        assertTrue(next.filters(null).isEmpty())
    }

    @Test
    fun `a run of pages with no video ends paging, and one reel resets it`() {
        val page = listOf(mapOf(ReelStream.VIDEO to 1_000L))
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
