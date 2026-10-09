package com.nostrvault.service

import com.nostrvault.ui.screens.HashtagNotesViewModel
import org.junit.Assert.assertEquals
import org.junit.Test

class HashtagSuggestionsTest {
    private fun note(vararg t: String) = t.map { listOf("t", it) }

    @Test
    fun countsNotesPerTag() {
        val notes = listOf(note("nostr", "bitcoin"), note("bitcoin"), note("bitcoin", "art"), note("art"))
        assertEquals(listOf("bitcoin", "art", "nostr"), HashtagSuggestions.top(notes, emptyList()))
    }

    @Test
    fun mergesCaseAndHashAndCountsANoteOnce() {
        val notes = listOf(
            note("Bitcoin", "bitcoin", " #BITCOIN "),
            note("nostr"),
            note("nostr"),
        )
        // The first note names bitcoin three ways but counts once.
        assertEquals(listOf("nostr", "bitcoin"), HashtagSuggestions.top(notes, emptyList()))
    }

    @Test
    fun ignoresOtherTagsAndEmptyNames() {
        val notes = listOf(listOf(listOf("p", "abc"), listOf("t"), listOf("t", "#"), listOf("t", "zap")))
        assertEquals(listOf("zap"), HashtagSuggestions.top(notes, emptyList()))
    }

    @Test
    fun excludesFollowed() {
        val notes = listOf(note("bitcoin"), note("bitcoin"), note("art"))
        assertEquals(listOf("art"), HashtagSuggestions.top(notes, listOf("Bitcoin")))
    }

    @Test
    fun capsAtLimit() {
        val notes = (1..20).map { note("tag$it") }
        assertEquals(8, HashtagSuggestions.top(notes, emptyList()).size)
        assertEquals(3, HashtagSuggestions.top(notes, emptyList(), limit = 3).size)
    }

    @Test
    fun tiesSortAlphabetically() {
        val notes = listOf(note("zeta"), note("alpha"), note("mid"), note("mid"))
        assertEquals(listOf("mid", "alpha", "zeta"), HashtagSuggestions.top(notes, emptyList()))
    }

    @Test
    fun filterValuesCarryCaseVariantsAndCap() {
        assertEquals(
            listOf("bitcoin", "Bitcoin", "BITCOIN", "a1", "A1"),
            HashtagNotesViewModel.tagFilterValues(listOf("#Bitcoin", "bitcoin", "a1")),
        )
        val many = (1..150).map { "t$it" }
        val values = HashtagNotesViewModel.tagFilterValues(many)
        assertEquals(HashtagNotesViewModel.MAX_TAGS, values.map { it.lowercase() }.toSet().size)
    }
}
