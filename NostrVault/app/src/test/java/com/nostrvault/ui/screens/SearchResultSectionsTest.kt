package com.nostrvault.ui.screens

import com.nostrvault.data.model.FeedNote
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SearchResultSectionsTest {

    private fun note(id: String, content: String) = FeedNote.fromEvent(
        id = id,
        pubkey = "pk",
        content = content,
        tags = emptyList(),
        createdAt = 1_700_000_000L,
        kind = 1,
    )

    @Test
    fun hashtagsAreThoseContainingTheQuery() {
        val notes = listOf(
            note("a", "Stacking #Bitcoin and #nostr today"),
            note("b", "#bitcoiners unite, #coffee"),
        )
        assertEquals(listOf("bitcoin", "bitcoiners"), SearchResultSections.hashtags(notes, "BITCOIN"))
        assertEquals(listOf("bitcoin", "bitcoiners"), SearchResultSections.hashtags(notes, "#bit"))
        assertEquals(emptyList<String>(), SearchResultSections.hashtags(notes, "#"))
    }

    @Test
    fun filterShowsOnlyItsSectionExceptAll() {
        val f = SearchResultFilter.entries
        for (section in f) {
            assertTrue(SearchResultSections.shows(SearchResultFilter.ALL, section))
            for (filter in f) {
                if (filter == SearchResultFilter.ALL) continue
                assertEquals(filter == section, SearchResultSections.shows(filter, section))
            }
        }
        assertFalse(SearchResultSections.shows(SearchResultFilter.USERS, SearchResultFilter.NOTES))
    }
}
