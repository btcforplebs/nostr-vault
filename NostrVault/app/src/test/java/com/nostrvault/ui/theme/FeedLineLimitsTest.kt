package com.nostrvault.ui.theme

import org.junit.Assert.assertEquals
import org.junit.Test

class FeedLineLimitsTest {
    @Test fun defaultsMatchTheOldFixedLimits() {
        val limits = FeedLineLimits()
        assertEquals(3, limits.compactLines)
        assertEquals(3, limits.threadedLines(isRoot = true))
        assertEquals(2, limits.threadedLines(isRoot = false))
    }

    @Test fun repliesShowOneFewerButNeverZero() {
        val limits = FeedLineLimits(compact = 5, threaded = 1)
        assertEquals(5, limits.compactLines)
        assertEquals(1, limits.threadedLines(isRoot = true))
        assertEquals(1, limits.threadedLines(isRoot = false))
    }

    @Test fun storedValuesOutsideTheRangeAreClamped() {
        val limits = FeedLineLimits(compact = 0, threaded = 99)
        assertEquals(FeedLineLimits.RANGE.first, limits.compactLines)
        assertEquals(FeedLineLimits.RANGE.last, limits.threadedLines(isRoot = true))
    }
}
