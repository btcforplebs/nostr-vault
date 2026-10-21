package com.nostrvault.ui.components

import com.nostrvault.data.model.GlobeEdge
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * A face's fade at the rim and on losing its seat. The seat case mirrors
 * HavenApp/MediaLogicTests/Tests/MediaLogicTests/GlobeEdgeTests.swift
 * `testASeatFadesInAQuarterSecondAndReduceMotionCuts`.
 */
class GlobeFaceFadeTest {
    private val depths = (0..3400).map { -1.7 + it * 0.001 }

    @Test fun `a seat fades in over a quarter second and Reduce Motion cuts`() {
        var fade = 0.0
        var t = 0.0
        while (fade < 1 && t < 2) {
            fade = GlobeFaceFade.seat(fade, seated = true, dt = 1.0 / 60, reduceMotion = false)
            t += 1.0 / 60
        }
        assertEquals(1.0, fade, 0.0)
        assertTrue(t > 0.2)
        assertTrue(t < 0.5)
        // The first frame only starts it: no pop.
        assertTrue(GlobeFaceFade.seat(0.0, seated = true, dt = 1.0 / 60, reduceMotion = false) < 0.25)
        assertEquals(1.0, GlobeFaceFade.seat(0.0, seated = true, dt = 1.0 / 60, reduceMotion = true), 0.0)
        assertEquals(0.0, GlobeFaceFade.seat(1.0, seated = false, dt = 1.0 / 60, reduceMotion = true), 0.0)
    }

    @Test fun `a seat fades out the same way and lands exactly on zero`() {
        var fade = 1.0
        var frames = 0
        while (fade > 0 && frames < 120) {
            fade = GlobeFaceFade.seat(fade, seated = false, dt = 1.0 / 60, reduceMotion = false)
            frames++
        }
        assertEquals(0.0, fade, 0.0)
        assertTrue(frames in 13..29)
        // No time passing, no change.
        assertEquals(0.5, GlobeFaceFade.seat(0.5, seated = true, dt = 0.0, reduceMotion = false), 0.0)
    }

    @Test fun `rolling to the rim a face shrinks onto its ember without a step`() {
        val dim = 0.8
        val faceR = 20.0
        var lastPicture = -1.0
        var lastEmber = Double.MAX_VALUE
        for (depth in depths) {
            val edge = GlobeFaceFade.edge(depth, isAuthor = false)
            val picture = GlobeFaceFade.pictureAlpha(dim, edge)
            val ember = GlobeFaceFade.emberAlpha(dim, edge)
            if (lastPicture >= 0) {
                // Never brightens rolling backward, and the ember never dims coming forward.
                assertTrue(picture >= lastPicture)
                assertTrue(ember <= lastEmber)
                // Small steps everywhere but the two cut-offs iOS also has.
                if (edge > 0.02 && edge < 0.98) {
                    assertTrue(abs(picture - lastPicture) < 0.01)
                    assertTrue(abs(ember - lastEmber) < 0.01)
                }
            }
            lastPicture = picture
            lastEmber = ember
            // Shrinks to three fifths, landing on the ember, not to a point.
            val r = GlobeEdge.faceRadius(faceR, edge)
            assertTrue(r >= faceR * 0.6 - 1e-9 && r <= faceR + 1e-9)
        }
        // Round the back: only the ember, small.
        val back = GlobeFaceFade.edge(-0.5, isAuthor = false)
        assertEquals(0.0, GlobeFaceFade.pictureAlpha(dim, back), 0.0)
        assertEquals(dim, GlobeFaceFade.emberAlpha(dim, back), 1e-12)
        assertEquals(3.2, GlobeFaceFade.emberRadius(back, 1.0, 1.0), 1e-12)
        // In front: only the face, the ember (were it shown) a touch bigger.
        val front = GlobeFaceFade.edge(1.0, isAuthor = false)
        assertEquals(dim, GlobeFaceFade.pictureAlpha(dim, front), 1e-12)
        assertEquals(0.0, GlobeFaceFade.emberAlpha(dim, front), 0.0)
        assertEquals(3.6, GlobeFaceFade.emberRadius(front, 1.0, 1.0), 1e-12)
    }

    @Test fun `the thresholds are iOS's`() {
        // GlobeEdge.faceGone / faceFull, and the 0.01 / 0.99 cut-offs in GlobeScene.draw.
        assertEquals(0.0, GlobeFaceFade.edge(-0.1, isAuthor = false), 0.0)
        assertEquals(1.0, GlobeFaceFade.edge(0.25, isAuthor = false), 0.0)
        assertEquals(0.5, GlobeFaceFade.edge(0.075, isAuthor = false), 1e-12)
        assertEquals(0.0, GlobeFaceFade.pictureAlpha(1.0, 0.01), 0.0)
        assertTrue(GlobeFaceFade.pictureAlpha(1.0, 0.011) > 0)
        assertEquals(0.0, GlobeFaceFade.emberAlpha(1.0, 0.99), 0.0)
        assertTrue(GlobeFaceFade.emberAlpha(1.0, 0.989) > 0)
    }

    @Test fun `the author never fades at the rim`() {
        for (depth in depths) assertEquals(1.0, GlobeFaceFade.edge(depth, isAuthor = true), 0.0)
    }

    @Test fun `seat fades carry between frames and forget faces that left`() {
        val fades = GlobeSeatFades()
        // New faces start where they are heading: no fade on the first frame.
        fades.begin()
        assertEquals(1.0, fades.step("a", seated = true, dt = 1.0 / 60, reduceMotion = false), 0.0)
        assertEquals(0.0, fades.step("b", seated = false, dt = 1.0 / 60, reduceMotion = false), 0.0)
        fades.end()
        assertFalse(fades.fading)
        // "a" loses its seat: it fades, and the clock is asked to keep running.
        fades.begin()
        val a = fades.step("a", seated = false, dt = 1.0 / 60, reduceMotion = false)
        fades.end()
        assertTrue(a > 0 && a < 1)
        assertTrue(fades.fading)
        // Next frame carries on from there.
        fades.begin()
        val a2 = fades.step("a", seated = false, dt = 1.0 / 60, reduceMotion = false)
        fades.end()
        assertTrue(a2 < a)
        // "a" was not drawn for a frame: it comes back where it is heading.
        fades.begin()
        fades.end()
        fades.begin()
        assertEquals(1.0, fades.step("a", seated = true, dt = 1.0 / 60, reduceMotion = false), 0.0)
        fades.end()
        assertFalse(fades.fading)
    }
}
