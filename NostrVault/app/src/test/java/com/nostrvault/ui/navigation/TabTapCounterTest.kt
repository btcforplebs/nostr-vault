package com.nostrvault.ui.navigation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Logen 26353911: a third quick tap on the same tab is a triple-tap. */
class TabTapCounterTest {
    private val gap = TabTapCounter.TAP_GAP_MS

    @Test fun `three quick taps on one tab are a triple-tap`() {
        val c = TabTapCounter()
        assertFalse(c.tap(Screen.Feed, 1_000))
        assertFalse("the second tap is still the plain reselect", c.tap(Screen.Feed, 1_000 + gap))
        assertTrue(c.tap(Screen.Feed, 1_000 + 2 * gap))
    }

    @Test fun `a pause starts the count over`() {
        val c = TabTapCounter()
        c.tap(Screen.Dashboard, 0)
        c.tap(Screen.Dashboard, 100)
        assertFalse(c.tap(Screen.Dashboard, 100 + gap + 1))
        assertFalse(c.tap(Screen.Dashboard, 200 + gap))
        assertTrue(c.tap(Screen.Dashboard, 300 + gap))
    }

    @Test fun `a tap on another tab starts the count over`() {
        val c = TabTapCounter()
        c.tap(Screen.Feed, 0)
        c.tap(Screen.Dashboard, 50)
        assertFalse(c.tap(Screen.Feed, 100))
        assertFalse(c.tap(Screen.Feed, 150))
        assertTrue(c.tap(Screen.Feed, 200))
    }

    @Test fun `after a triple-tap the next taps count from one`() {
        val c = TabTapCounter()
        repeat(3) { c.tap(Screen.Feed, it * 100L) }
        val after = (3..5).map { c.tap(Screen.Feed, it * 100L) }
        assertEquals(listOf(false, false, true), after)
    }
}
