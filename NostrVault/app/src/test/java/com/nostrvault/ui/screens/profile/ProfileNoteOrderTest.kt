package com.nostrvault.ui.screens.profile

import com.nostrvault.data.model.FeedNote
import org.junit.Assert.assertEquals
import org.junit.Test

/** The in-place insert matches the full re-sort it replaces (perf review #7). */
class ProfileNoteOrderTest {
    private fun note(id: Int, at: Long) = FeedNote.fromEvent(
        id = id.toString().padStart(64, '0'), pubkey = "a".repeat(64), content = "x", tags = emptyList(),
        createdAt = at, kind = 1, verify = { true },
    )

    @Test
    fun matchesTheFullSortWhateverOrderNotesArriveIn() {
        val times = listOf(50L, 10L, 90L, 50L, 70L, 10L, 100L, 1L, 50L)
        var inserted = emptyList<FeedNote>()
        var sorted = emptyList<FeedNote>()
        times.forEachIndexed { i, at ->
            val n = note(i, at)
            inserted = ProfileNoteOrder.inserted(inserted, n)
            sorted = (sorted + n).sortedByDescending { it.createdAt }
        }
        assertEquals(sorted.map { it.id }, inserted.map { it.id })
    }
}
