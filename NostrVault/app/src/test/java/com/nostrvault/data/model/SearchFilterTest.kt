package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Date

/** Mirrors HavenApp/MediaLogicTests/Tests/MediaLogicTests/SearchFilterTests.swift, plus [SearchFilter.apply]. */
class SearchFilterTest {
    private val me = "aa"
    private val friend = "bb"
    private val stranger = "cc"
    private val follows = setOf(friend)
    private val now = Date(1_800_000_000_000L)
    private fun ago(seconds: Long) = Date(now.time - seconds * 1000)

    @Test fun defaultIsOffAndHasNoSummary() {
        assertFalse(SearchFilter.ALL.isActive)
        assertNull(SearchFilter.ALL.summary)
        assertEquals("No filter", SearchFilter.ALL.accessibilitySummary)
    }

    @Test fun everyoneLetsEveryAuthorThrough() {
        for (author in listOf(me, friend, stranger)) assertTrue(SearchFilter.ALL.allowsAuthor(author, me, follows))
    }

    @Test fun followsKeepsOnlyFollowedAuthors() {
        val scope = SearchFilter(who = SearchFilter.Who.FOLLOWS)
        assertTrue(scope.allowsAuthor(friend, me, follows))
        assertFalse(scope.allowsAuthor(me, me, follows))
        assertFalse(scope.allowsAuthor(stranger, me, follows))
    }

    @Test fun youKeepsOnlyTheOwnAccount() {
        val scope = SearchFilter(who = SearchFilter.Who.YOU)
        assertTrue(scope.allowsAuthor(me, me, follows))
        assertFalse(scope.allowsAuthor(friend, me, follows))
    }

    /** Browse-only installs have no account; "You" must then show nothing, not fall open to everyone. */
    @Test fun youWithNoAccountMatchesNothing() {
        val scope = SearchFilter(who = SearchFilter.Who.YOU)
        assertFalse(scope.allowsAuthor(me, null, follows))
        assertFalse(scope.allowsAuthor(me, "", follows))
    }

    @Test fun anyTimeHasNoWindow() {
        assertTrue(SearchFilter.ALL.allowsDate(Date(0), now))
    }

    @Test fun whenWindowsAreInclusiveAtTheEdge() {
        val day = SearchFilter(period = SearchFilter.Period.DAY)
        assertTrue(day.allowsDate(ago(24 * 3600), now))
        assertFalse(day.allowsDate(ago(24 * 3600 + 1), now))
        // Not rounded down to the second: half a second past the edge is past it.
        assertFalse(day.allowsDate(Date(ago(24 * 3600).time - 500), now))
        val week = SearchFilter(period = SearchFilter.Period.WEEK)
        assertTrue(week.allowsDate(ago(6 * 24 * 3600), now))
        assertFalse(week.allowsDate(ago(8 * 24 * 3600), now))
        val month = SearchFilter(period = SearchFilter.Period.MONTH)
        assertTrue(month.allowsDate(ago(29 * 24 * 3600), now))
        assertFalse(month.allowsDate(ago(31 * 24 * 3600), now))
    }

    @Test fun futureDatedNotesPassEveryWindow() {
        for (period in SearchFilter.Period.entries) {
            assertTrue(period.name, SearchFilter(period = period).allowsDate(Date(now.time + 60_000), now))
        }
    }

    @Test fun summaryNamesOnlyWhatIsOn() {
        assertEquals("Follows", SearchFilter(who = SearchFilter.Who.FOLLOWS).summary)
        assertEquals("Week", SearchFilter(period = SearchFilter.Period.WEEK).summary)
        assertEquals("You · 24 h", SearchFilter(SearchFilter.Who.YOU, SearchFilter.Period.DAY).summary)
        assertEquals("You, Last 24 hours", SearchFilter(SearchFilter.Who.YOU, SearchFilter.Period.DAY).accessibilitySummary)
    }

    @Test fun captionUsesFullLabelsForOnlyWhatIsOn() {
        assertNull(SearchFilter.ALL.caption)
        assertEquals("People you follow", SearchFilter(who = SearchFilter.Who.FOLLOWS).caption)
        assertEquals("Last week", SearchFilter(period = SearchFilter.Period.WEEK).caption)
        assertEquals("People you follow · Last week", SearchFilter(SearchFilter.Who.FOLLOWS, SearchFilter.Period.WEEK).caption)
    }

    /** Profiles by who, notes by who and when, order kept; off returns the results as they are. */
    @Test fun applyNarrowsProfilesByWhoAndNotesByWhoAndWhen() {
        fun note(id: String, by: String, secondsAgo: Long) =
            FeedNote.fromEvent(id, by, "x", emptyList(), (now.time / 1000) - secondsAgo, 1)
        val results = GlobalSearchResults(
            profiles = listOf(FeedProfile(stranger), FeedProfile(friend), FeedProfile(me)),
            notes = listOf(note("1", friend, 60), note("2", stranger, 60), note("3", friend, 10 * 24 * 3600)),
        )
        assertEquals(results, SearchFilter.ALL.apply(results, me, follows, now))
        val narrowed = SearchFilter(SearchFilter.Who.FOLLOWS, SearchFilter.Period.WEEK).apply(results, me, follows, now)
        assertEquals(listOf(friend), narrowed.profiles.map { it.pubkey })
        assertEquals(listOf("1"), narrowed.notes.map { it.id })
    }
}
