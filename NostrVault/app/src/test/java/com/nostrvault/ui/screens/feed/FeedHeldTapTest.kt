package com.nostrvault.ui.screens.feed

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Holding the tapped condensed row while a bigger open one above closes (iOS PR #1258). */
class FeedHeldTapTest {

    @Test
    fun openRowAboveHoldsTheTappedRowWhereItWas() {
        assertEquals(5 to -1075, heldTapPosition(openIndex = 3, tappedIndex = 5, tappedOffset = 1075))
    }

    @Test
    fun tappedRowPartlyUnderTheTopKeepsItsOffset() {
        assertEquals(5 to 40, heldTapPosition(openIndex = 0, tappedIndex = 5, tappedOffset = -40))
    }

    @Test
    fun nothingOpenLeavesTheListAlone() {
        assertNull(heldTapPosition(openIndex = null, tappedIndex = 5, tappedOffset = 300))
    }

    @Test
    fun openRowBelowLeavesTheListAlone() {
        assertNull(heldTapPosition(openIndex = 7, tappedIndex = 5, tappedOffset = 300))
    }

    @Test
    fun openRowNoLongerInTheFeedLeavesTheListAlone() {
        assertNull(heldTapPosition(openIndex = -1, tappedIndex = 5, tappedOffset = 300))
    }
}
