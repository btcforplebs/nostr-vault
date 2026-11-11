package com.nostrvault.ui.theme

import org.junit.Assert.assertEquals
import org.junit.Test

class FeedLineLimitsTest {
    @Test fun defaults() {
        val limits = FeedLineLimits()
        assertEquals(5, limits.threadedLines(isRoot = true))
        assertEquals(4, limits.threadedLines(isRoot = false))
    }

    @Test fun repliesShowOneFewerButNeverZero() {
        val limits = FeedLineLimits(threaded = 1)
        assertEquals(1, limits.threadedLines(isRoot = true))
        assertEquals(1, limits.threadedLines(isRoot = false))
    }

    @Test fun storedValuesOutsideTheRangeAreClamped() {
        assertEquals(FeedLineLimits.RANGE.first, FeedLineLimits(threaded = 0).threadedLines(isRoot = true))
        assertEquals(FeedLineLimits.RANGE.last, FeedLineLimits(threaded = 99).threadedLines(isRoot = true))
    }

    @Test fun theRetiredCompactValueIsIgnored() {
        assertEquals(FeedLineLimits(threaded = 7), FeedLineLimits(1, 7))
    }
}
