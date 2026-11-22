package com.nostrvault.ui.screens.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/** Follow Distance is shown in true hops: you are never a hop (iOS FollowDistanceWordsTests). */
class FollowDistanceWordsTest {

    @Test
    fun levelsReadAsTrueHops() {
        assertEquals("Only you", FollowDistanceWords.short(1))
        assertEquals("1 hop", FollowDistanceWords.short(2))
        assertEquals("2 hops", FollowDistanceWords.short(3))
    }

    @Test
    fun reachLine() {
        assertEquals("Only you. Everyone else is kept out.", FollowDistanceWords.reachDetail(1))
        assertEquals("People within 1 hop of you. Everyone else is kept out.", FollowDistanceWords.reachDetail(2))
        assertEquals("People within 2 hops of you. Everyone else is kept out.", FollowDistanceWords.reachDetail(3))
    }

    /** A level saved by an older build (0, 4, 5) reads as what the relay runs. */
    @Test
    fun outOfRangeLevelsReadAsTheNearestRealOne() {
        assertEquals("Only you", FollowDistanceWords.short(0))
        assertEquals("2 hops", FollowDistanceWords.short(5))
    }

    /** No screen prints the raw level any more. */
    @Test
    fun everyLevelTheStepperOffersHasWords() {
        for (level in RelayAccessLimits.FOLLOW_DISTANCE) {
            assertFalse("level $level shown raw", FollowDistanceWords.short(level).contains("$level hop"))
        }
    }
}
