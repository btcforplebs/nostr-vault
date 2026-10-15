package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/** Mirrors HavenApp/MediaLogicTests/Tests/MediaLogicTests/GlobeEdgeTests.swift. */
class GlobeEdgeTest {
    // stride(from: -1.7, through: 1.7, by: 0.001)
    private val depths = (0..3400).map { -1.7 + it * 0.001 }

    @Test fun aFaceFadesOutTowardTheRimWithoutAStep() {
        // Whole in front, gone round the back where it loses its seat.
        assertEquals(1.0, GlobeEdge.face(1.0), 0.0)
        assertEquals(0.0, GlobeEdge.face(GlobeEdge.FACE_GONE), 0.0)
        // Smooth, and it never brightens rolling backward.
        for ((a, b) in depths.zipWithNext()) {
            val fa = GlobeEdge.face(a)
            val fb = GlobeEdge.face(b)
            assertTrue(abs(fb - fa) < 0.01)
            assertTrue(fb >= fa)
        }
        // It shrinks onto its ember, not to nothing.
        assertEquals(6.0, GlobeEdge.faceRadius(10.0, 0.0), 0.0)
        assertEquals(10.0, GlobeEdge.faceRadius(10.0, 1.0), 0.0)
    }

    @Test fun aLiveStarDimsRoundTheBackWithoutAStep() {
        assertEquals(1.0, GlobeEdge.arc(1.0), 0.0)
        assertEquals(0.35, GlobeEdge.arc(-1.0), 1e-12)
        for ((a, b) in depths.zipWithNext()) {
            assertTrue(abs(GlobeEdge.arc(b) - GlobeEdge.arc(a)) < 0.01)
        }
    }

    // Skipped: aSeatFadesInAQuarterSecondAndReduceMotionCuts — GlobeEdge.seat is not ported.
}
