package com.nostrvault.ui.components

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The threads' bands and glow, as iOS `GlobeScene.draw` works them out. */
class GlobeThreadsTest {
    @Test fun `twelve bands cover back to front`() {
        assertEquals(12, GlobeThreads.BANDS)
        assertEquals(0, GlobeThreads.band(0.0))
        assertEquals(0, GlobeThreads.band(-0.3))
        assertEquals(11, GlobeThreads.band(1.0))
        assertEquals(11, GlobeThreads.band(1.4))
        assertEquals(5, GlobeThreads.band(0.5 - 1e-9))
        assertEquals(6, GlobeThreads.band(0.5))
        // Every front lands in the band whose span holds it.
        for (i in 0..1000) {
            val front = i / 1000.0
            val band = GlobeThreads.band(front)
            assertTrue(front >= band / 12.0 - 1e-12)
            assertTrue(front < (band + 1) / 12.0 || band == 11)
        }
    }

    @Test fun `band brightness is iOS's curve and steps finely`() {
        // 0.10 + 0.75 * front², front at the band's middle.
        assertEquals(0.10 + 0.75 * (0.5 / 12) * (0.5 / 12), GlobeThreads.bandAlpha(0), 1e-12)
        assertEquals(0.10 + 0.75 * (11.5 / 12) * (11.5 / 12), GlobeThreads.bandAlpha(11), 1e-12)
        for (level in 1 until GlobeThreads.BANDS) {
            val step = GlobeThreads.bandAlpha(level) - GlobeThreads.bandAlpha(level - 1)
            assertTrue(step > 0)
            // Four bands stepped by up to 0.375; twelve keep each step small.
            assertTrue(step < 0.13)
        }
    }

    @Test fun `the glow ramps in toward the front instead of switching on`() {
        // No glow in the back bands (front below 0.45), full ramp by 0.8.
        for (level in 0 until GlobeThreads.BANDS) {
            val front = GlobeThreads.bandFront(level)
            val glow = GlobeThreads.glowAlpha(level)
            if (front <= 0.45) assertEquals(0.0, glow, 0.0)
            if (front >= 0.8) assertEquals(GlobeThreads.bandAlpha(level) * 0.6, glow, 1e-12)
        }
        val lit = (0 until GlobeThreads.BANDS).filter { GlobeThreads.glowAlpha(it) > GlobeThreads.GLOW_MIN }
        // Several bands ramp, not one step.
        assertTrue(lit.size >= 5)
        for ((a, b) in lit.zipWithNext()) assertTrue(GlobeThreads.glowAlpha(b) > GlobeThreads.glowAlpha(a))
        val ramp = lit.filter { GlobeThreads.bandFront(it) < 0.8 }
        assertTrue(ramp.size >= 3)
        for ((a, b) in lit.zipWithNext()) assertTrue(GlobeThreads.glowAlpha(b) - GlobeThreads.glowAlpha(a) < 0.2)
    }
}
