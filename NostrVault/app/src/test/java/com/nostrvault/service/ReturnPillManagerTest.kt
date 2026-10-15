package com.nostrvault.service

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Before
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The return pill's gathering: one sound for the first, silence after, nothing gathered while away. */
@OptIn(ExperimentalCoroutinesApi::class)
class ReturnPillManagerTest {
    private val back = 1_800_000_000_000L

    @Before fun setUp() = Dispatchers.setMain(UnconfinedTestDispatcher())
    @After fun tearDown() = Dispatchers.resetMain()

    @Test fun theFirstArrivalSoundsTheRestAreSilentAndLiveTrafficIsNotGathered() {
        ReturnPillManager.beginReturn(back)
        assertEquals(ReturnPillManager.Gathered.FIRST, ReturnPillManager.gather("mention", "m1", now = back + 1_000))
        assertEquals(ReturnPillManager.Gathered.ADDED, ReturnPillManager.gather("zap", "z1", now = back + 2_000))
        assertEquals("1 mention · 1 zap", ReturnPillManager.text.value)
        assertTrue(ReturnPillManager.isShowing.value)
        // Long after the return, a fresh event is live traffic: a top pill.
        assertEquals(ReturnPillManager.Gathered.NO, ReturnPillManager.gather("reply", "r1", createdAt = back + 59_000, now = back + 60_000))
        ReturnPillManager.endReturn()
        assertFalse(ReturnPillManager.isShowing.value)
        // Away: nothing is gathered into a pill nobody can see.
        assertEquals(ReturnPillManager.Gathered.NO, ReturnPillManager.gather("mention", "m2", now = back + 3_000))
    }

    /** The folded strangers' alert keeps one id however many follow: each call counts. */
    @Test fun eachFoldedFollowerCounts() {
        ReturnPillManager.beginReturn(back)
        ReturnPillManager.gather("followers", "followers-npub", now = back + 1_000)
        ReturnPillManager.gather("followers", "followers-npub", now = back + 1_500)
        assertEquals("2 new followers", ReturnPillManager.text.value)
        ReturnPillManager.endReturn()
    }
}
