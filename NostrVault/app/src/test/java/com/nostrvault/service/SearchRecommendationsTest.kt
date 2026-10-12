package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.Date

/** Mirrors iOS `SearchRecommendationsTests`. */
class SearchRecommendationsTest {
    // People

    @Test
    fun peopleMostVouchedFirstSkippingFollowsSelfAndBlocked() {
        val vouches = mapOf("a" to 5, "b" to 9, "me" to 20, "f" to 30, "x" to 12, "c" to 5)
        val people = SearchRecommendations.people(vouches, following = setOf("f"), owner = "me", blocked = setOf("x"))
        assertEquals(listOf("b", "a", "c"), people.map { it.pubkey })
        assertEquals(9, people.first().vouches)
    }

    @Test
    fun peopleNeedTwoVouches() {
        val people = SearchRecommendations.people(mapOf("a" to 1, "b" to 2), emptySet(), "me", emptySet())
        assertEquals(listOf("b"), people.map { it.pubkey })
    }

    @Test
    fun peopleCapped() {
        val vouches = (0 until 20).associate { "p$it" to 3 }
        assertEquals(4, SearchRecommendations.people(vouches, emptySet(), "me", emptySet(), limit = 4).size)
    }

    // Notes

    private fun note(id: String, pubkey: String, tags: List<String>, t: Long = 0) =
        SearchRecommendations.Candidate(id, pubkey, tags.map { listOf("t", it) }, Date(t * 1000))

    @Test
    fun notesNeedAnInterestAndRankByHits() {
        val notes = listOf(
            note("1", "a", listOf("art")),
            note("2", "b", listOf("art", "Music")),
            note("3", "c", listOf("cooking")),
        )
        val ids = SearchRecommendations.notes(notes, setOf("art", "#music"), emptySet(), emptyMap(), "me", emptySet())
        assertEquals(listOf("2", "1"), ids)
    }

    @Test
    fun notesPreferFollowsThenVouchesThenNewest() {
        val notes = listOf(
            note("stranger", "s", listOf("art"), 300),
            note("vouched", "v", listOf("art"), 100),
            note("followed", "f", listOf("art"), 0),
            note("newer-stranger", "n", listOf("art"), 400),
        )
        val ids = SearchRecommendations.notes(notes, setOf("art"), setOf("f"), mapOf("v" to 4), "me", emptySet())
        assertEquals(listOf("followed", "vouched", "newer-stranger", "stranger"), ids)
    }

    @Test
    fun notesOnePerAuthorAndSkipOwnAndBlocked() {
        val notes = listOf(
            note("a1", "a", listOf("art"), 2),
            note("a2", "a", listOf("art"), 1),
            note("mine", "me", listOf("art")),
            note("bad", "x", listOf("art")),
        )
        val ids = SearchRecommendations.notes(notes, setOf("art"), emptySet(), emptyMap(), "me", setOf("x"))
        assertEquals(listOf("a1"), ids)
    }

    @Test
    fun noInterestsNoNotes() {
        assertEquals(
            emptyList<String>(),
            SearchRecommendations.notes(listOf(note("1", "a", listOf("art"))), emptySet(), emptySet(), emptyMap(), "me", emptySet()),
        )
    }

    @Test
    fun notesSkipSeen() {
        val ids = SearchRecommendations.notes(
            listOf(note("1", "a", listOf("art")), note("2", "b", listOf("art"))),
            setOf("art"), emptySet(), emptyMap(), "me", emptySet(), seen = setOf("1"),
        )
        assertEquals(listOf("2"), ids)
    }

    // Interests

    @Test
    fun interestsFollowedFirstThenEngagedByUse() {
        val engaged = listOf(
            listOf(listOf("t", "Music")), listOf(listOf("t", "music")),
            listOf(listOf("t", "art")), listOf(listOf("t", "Bitcoin")),
        )
        assertEquals(
            listOf("bitcoin", "nostr", "music", "art"),
            SearchRecommendations.interests(listOf("#Bitcoin", "nostr"), engaged),
        )
    }

    @Test
    fun interestsCapped() {
        val engaged = (0 until 20).map { listOf(listOf("t", "t$it")) }
        assertEquals(4, SearchRecommendations.interests(listOf("a", "b"), engaged, limit = 4).size)
    }
}
