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

    /**
     * The relay's catch-up round runs on every background wake. Its "summary"
     * (FeedActivityNotifier.claimRelaySummary) fires as on iOS: after 2 h
     * away, once per absence, again only after the app has been opened.
     */
    @Test fun `the relay summary fires once per absence of two hours`() {
        val t0 = 1_800_000_000L
        val h = 3_600L
        var announced: Long? = null
        fun wake(at: Long, foreground: Long): Boolean =
            FeedNotesPolicy.shouldAnnounceAbsenceSummary(at, foreground, announced).also { if (it) announced = at }

        assertFalse("1 h away is not an absence", wake(t0 + h, t0))
        assertTrue("3 h away announces", wake(t0 + 3 * h, t0))
        assertFalse("a later wake in the same absence stays quiet", wake(t0 + 4 * h, t0))
        val back = t0 + 5 * h
        assertFalse("just after opening the app", wake(back + h, back))
        assertTrue("the next long absence announces again", wake(back + 3 * h, back))
    }
}
