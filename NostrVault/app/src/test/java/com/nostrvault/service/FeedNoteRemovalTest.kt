package com.nostrvault.service

import com.nostrvault.data.model.FeedNote
import org.junit.Assert.assertEquals
import org.junit.Test

/** A deleted note leaves every list and cache it could come back from. */
class FeedNoteRemovalTest {
    private fun note(id: String) = FeedNote.fromEvent(id.padEnd(64, '0'), "a".repeat(64), id, emptyList(), 1_000L, 1)
    private val keep1 = note("keep1")
    private val gone = note("gone")
    private val keep2 = note("keep2")

    @Test
    fun `the deleted note leaves a list and nothing else does`() {
        assertEquals(listOf(keep1, keep2), FeedNoteRemoval.without(listOf(keep1, gone, keep2), gone.id))
    }

    @Test
    fun `the deleted note leaves the parent cache under any key`() {
        val cache = mapOf(keep1.id to keep1, gone.id to gone, "reply-hint" to gone)
        assertEquals(mapOf(keep1.id to keep1), FeedNoteRemoval.without(cache, gone.id))
    }

    @Test
    fun `an id that is not loaded changes nothing`() {
        val notes = listOf(keep1, keep2)
        assertEquals(notes, FeedNoteRemoval.without(notes, "missing".padEnd(64, '0')))
        val cache = mapOf(keep1.id to keep1)
        assertEquals(cache, FeedNoteRemoval.without(cache, "missing".padEnd(64, '0')))
    }
}
