package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Test

class WotUnlockTest {
    private val me = "a".repeat(64)

    @Test fun `your own key in your list does not count`() {
        assertEquals(2, WotUnlock.followCount(listOf(me, "b", "c"), me))
        assertEquals(0, WotUnlock.followCount(listOf(me), me))
        assertEquals(1, WotUnlock.followCount(listOf("B", "b", me.uppercase()), me))
    }

    @Test fun `five follows unlock`() {
        assertEquals(5, WotUnlock.followsNeeded(0))
        assertEquals(1, WotUnlock.followsNeeded(4))
        assertEquals(0, WotUnlock.followsNeeded(5))
        assertEquals(0, WotUnlock.followsNeeded(300))
    }

    @Test fun `the progress line counts down`() {
        assertEquals("Follow 5 more people to unlock Everyone", WotUnlock.progressLine(5))
        assertEquals("Follow 3 more people to unlock Everyone", WotUnlock.progressLine(3))
        assertEquals("Follow 1 more person to unlock Everyone", WotUnlock.progressLine(1))
    }
}
