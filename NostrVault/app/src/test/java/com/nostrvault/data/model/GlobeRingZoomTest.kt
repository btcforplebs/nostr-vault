package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/** The Hop layers' zoom out to an outer ring. iOS `GlobeRingZoomTests.swift`. */
class GlobeRingZoomTest {
    private val outline = 150.0
    private val half = 200.0

    @Test fun `hops map to levels and your circle to zero`() {
        assertEquals(0.0, GlobeRingZoom.level(null), 0.0)
        assertEquals(1.0, GlobeRingZoom.level(3), 0.0)
        assertEquals(2.0, GlobeRingZoom.level(4), 0.0)
        assertEquals(3.0, GlobeRingZoom.level(5), 0.0)
        assertEquals(3.0, GlobeRingZoom.level(9), 0.0)
        assertEquals(GlobeRingZoom.level(5), GlobeRingZoom.level(TrustMap.Layer.HOP5.hop), 0.0)
    }

    @Test fun `level zero is the globe as it was`() {
        assertEquals(1.0, GlobeRingZoom.innerScale(0.0), 0.0)
        assertEquals(1.0, GlobeRingZoom.innerAlpha(0.0), 0.0)
        assertEquals(outline * 1.72, GlobeRingZoom.radius(3, 0.0, outline, half), 1e-9)
        assertEquals(outline * (1.72 + 2 * 0.26), GlobeRingZoom.radius(5, 0.0, outline, half), 1e-9)
        for (hop in 3..5) {
            assertEquals(1.0, GlobeRingZoom.visibility(hop, 0.0), 0.0)
            assertEquals(0.0, GlobeRingZoom.emphasis(hop, 0.0), 0.0)
        }
    }

    @Test fun `the picked ring fills the frame and the globe shrinks and fades`() {
        for (hop in 3..5) {
            val level = GlobeRingZoom.level(hop)
            assertEquals(GlobeRingZoom.FIT * half, GlobeRingZoom.radius(hop, level, outline, half), 1e-9)
            assertEquals(1.0, GlobeRingZoom.emphasis(hop, level), 0.0)
            assertEquals(1.0, GlobeRingZoom.visibility(hop, level), 0.0)
            assertTrue(GlobeRingZoom.innerScale(level) < 0.5)
            assertTrue("the globe fades, never goes", GlobeRingZoom.innerAlpha(level) in 0.01..0.99)
        }
        assertTrue(GlobeRingZoom.innerScale(1.0) > GlobeRingZoom.innerScale(3.0))
    }

    @Test fun `rings inside the picked one close in and ones past it go`() {
        fun r(hop: Int) = GlobeRingZoom.radius(hop, 3.0, outline, half)
        assertTrue(GlobeRingZoom.innerOutline(3.0, outline) < r(3))
        assertTrue(r(3) < r(4) && r(4) < r(5))
        assertEquals("evenly spaced", r(4) - r(3), r(5) - r(4), 1e-9)
        assertEquals(GlobeRingZoom.INSIDE_ALPHA, GlobeRingZoom.visibility(3, 3.0), 0.0)
        assertEquals(0.0, GlobeRingZoom.visibility(5, 1.0), 0.0)
        assertEquals(0.0, GlobeRingZoom.emphasis(3, 3.0), 0.0)
    }

    @Test fun `it eases smoothly between levels`() {
        for (hop in 3..5) {
            var last = GlobeRingZoom.radius(hop, 0.0, outline, half)
            for (step in 1..300) {
                val level = step / 100.0
                val now = GlobeRingZoom.radius(hop, level, outline, half)
                assertTrue("hop $hop jumped at $level", abs(now - last) < 6)
                last = now
            }
        }
        assertEquals((1 + GlobeRingZoom.INNER_SCALES[1]) / 2, GlobeRingZoom.innerScale(0.5), 1e-9)
        assertEquals(1.0, GlobeRingZoom.innerScale(Double.NaN), 0.0)
        assertEquals(GlobeRingZoom.INNER_SCALES[3], GlobeRingZoom.innerScale(7.0), 0.0)
    }
}
