package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors the iOS NotificationPolicy feed-summary tests. */
class FeedNotesPolicyTest {
    private val hour = 3600L

    @Test fun neverForegroundedMeansNoAbsence() {
        assertFalse(FeedNotesPolicy.shouldAnnounceAbsenceSummary(10 * hour, null, null))
    }

    @Test fun aShortAbsenceIsNotAway() {
        assertFalse(FeedNotesPolicy.shouldAnnounceAbsenceSummary(10 * hour, 10 * hour - 2 * hour + 1, null))
        assertTrue(FeedNotesPolicy.shouldAnnounceAbsenceSummary(10 * hour, 8 * hour, null))
    }

    @Test fun oneSummaryPerAbsence() {
        // Announced after the absence began: already covered.
        assertFalse(FeedNotesPolicy.shouldAnnounceAbsenceSummary(12 * hour, 8 * hour, 10 * hour))
        // Announced in an earlier absence: this one is new.
        assertTrue(FeedNotesPolicy.shouldAnnounceAbsenceSummary(12 * hour, 8 * hour, 5 * hour))
    }

    @Test fun countsOnlyNotesNewerThanTheWatermark() {
        assertEquals(2, FeedNotesPolicy.unannouncedFeedNoteCount(listOf(90, 100, 101, 150), 100))
        assertEquals(0, FeedNotesPolicy.unannouncedFeedNoteCount(listOf(90, 150), null))
    }

    @Test fun feedSwitchesDecideWhatCounts() {
        val reply = listOf(listOf("e", "abc", "", "reply"))
        val mention = listOf(listOf("e", "abc", "", "mention"))
        assertTrue(FeedNotesPolicy.countsAsFeedNote(1, emptyList(), showReplies = false, showReposts = false))
        assertFalse(FeedNotesPolicy.countsAsFeedNote(1, reply, showReplies = false, showReposts = false))
        assertTrue(FeedNotesPolicy.countsAsFeedNote(1, reply, showReplies = true, showReposts = false))
        assertTrue(FeedNotesPolicy.countsAsFeedNote(1, mention, showReplies = false, showReposts = false))
        assertFalse(FeedNotesPolicy.countsAsFeedNote(6, emptyList(), showReplies = true, showReposts = false))
        assertTrue(FeedNotesPolicy.countsAsFeedNote(6, emptyList(), showReplies = true, showReposts = true))
        assertFalse(FeedNotesPolicy.countsAsFeedNote(7, emptyList(), showReplies = true, showReposts = true))
    }
}
