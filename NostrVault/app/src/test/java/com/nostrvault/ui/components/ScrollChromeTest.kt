package com.nostrvault.ui.components

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The finger-following fold: how far a drag folds the chrome, the cap near
 * the top of a list, and where a release settles.
 */
class ScrollChromeTest {
    private val travel = 100f

    @Before fun start() = ScrollChrome.reset()
    @After fun end() = ScrollChrome.reset()

    private fun scrolledFarDown() = ScrollChrome.reportTop(index = 5, offsetPx = 0, travelPx = travel, scope = null)

    @Test fun `a drag folds by the distance scrolled`() {
        scrolledFarDown()
        ScrollChrome.drag(30f, travel)
        assertEquals(0.3f, ScrollChrome.progress, 1e-4f)
        ScrollChrome.drag(-10f, travel)
        assertEquals(0.2f, ScrollChrome.progress, 1e-4f)
    }

    @Test fun `progress stays between shown and folded`() {
        scrolledFarDown()
        ScrollChrome.drag(500f, travel)
        assertEquals(1f, ScrollChrome.progress, 0f)
        assertTrue(ScrollChrome.isFolded)
        ScrollChrome.drag(-500f, travel)
        assertEquals(0f, ScrollChrome.progress, 0f)
        assertFalse(ScrollChrome.isFolded)
    }

    @Test fun `near the top the fold is capped by the distance left`() {
        ScrollChrome.reportTop(index = 0, offsetPx = 40, travelPx = travel, scope = null)
        ScrollChrome.drag(90f, travel)
        assertEquals(0.4f, ScrollChrome.progress, 1e-4f)
    }

    @Test fun `release settles near the top, then by fling, then to the nearer end`() {
        // Within the top's reach: always shown, even after a hard fling down.
        assertEquals(0f, ScrollChrome.settleTarget(0.9f, -5_000f, topCap = 0.5f))
        // A decided fling wins over position (finger up = negative = fold).
        assertEquals(1f, ScrollChrome.settleTarget(0.1f, -2_000f, topCap = null))
        assertEquals(0f, ScrollChrome.settleTarget(0.9f, 2_000f, topCap = null))
        // A slow release goes to whichever end is nearer.
        assertEquals(1f, ScrollChrome.settleTarget(0.6f, 0f, topCap = null))
        assertEquals(0f, ScrollChrome.settleTarget(0.4f, 100f, topCap = null))
        // Far from the top, the cap no longer applies.
        assertEquals(1f, ScrollChrome.settleTarget(0.7f, 0f, topCap = 3f))
    }

    @Test fun `fold curves never sit at similar strengths`() {
        // What folds away is gone by 60%; what the fold reveals starts at 40%.
        assertEquals(1f, ScrollChrome.fadeOut(0f), 0f)
        assertEquals(0.5f, ScrollChrome.fadeOut(0.3f), 1e-4f)
        assertEquals(0f, ScrollChrome.fadeOut(0.6f), 0f)
        assertEquals(0f, ScrollChrome.fadeOut(1f), 0f)
        assertEquals(0f, ScrollChrome.fadeIn(0f), 0f)
        assertEquals(0f, ScrollChrome.fadeIn(0.4f), 0f)
        assertEquals(0.5f, ScrollChrome.fadeIn(0.7f), 1e-4f)
        assertEquals(1f, ScrollChrome.fadeIn(1f), 0f)
    }

    @Test fun `reset shows the chrome`() {
        scrolledFarDown()
        ScrollChrome.drag(80f, travel)
        ScrollChrome.reset()
        assertEquals(0f, ScrollChrome.progress, 0f)
    }
}
