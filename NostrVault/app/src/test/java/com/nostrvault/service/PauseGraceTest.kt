package com.nostrvault.service

import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The feed keeps its sockets through a short trip to the background. */
class PauseGraceTest {
    @Test
    fun `back inside the grace, nothing is torn down`() = runTest {
        var torn = 0
        val grace = PauseGrace(backgroundScope, 60_000) { torn++ }
        grace.pause()
        advanceTimeBy(59_000)
        assertTrue(grace.resume())
        advanceTimeBy(120_000)
        assertEquals(0, torn)
    }

    @Test
    fun `past the grace, the teardown runs once and resume says so`() = runTest {
        var torn = 0
        val grace = PauseGrace(backgroundScope, 60_000) { torn++ }
        grace.pause()
        grace.pause() // a second stop doesn't restart or double it
        advanceTimeBy(60_001)
        runCurrent()
        assertEquals(1, torn)
        assertFalse(grace.resume())
    }

    @Test
    fun `a resume with no pause is not inside a grace`() = runTest {
        val grace = PauseGrace(backgroundScope, 60_000) {}
        assertFalse(grace.resume())
    }

    @Test
    fun `each trip gets its own grace`() = runTest {
        var torn = 0
        val grace = PauseGrace(backgroundScope, 60_000) { torn++ }
        grace.pause()
        advanceTimeBy(50_000)
        grace.resume()
        grace.pause()
        advanceTimeBy(50_000)
        assertEquals("the first trip's timer is gone", 0, torn)
        advanceTimeBy(10_001)
        runCurrent()
        assertEquals(1, torn)
    }
}
