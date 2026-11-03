package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.acos
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Letting go of the globe is one motion: the release speed carries on, dies
 * away and lands in the slow drift the way it was thrown, with no stop and no
 * wait between (Logen, 11/03). iOS GlobeFlickTests.
 */
class GlobeFlickTest {
    /** The angle turned over one short step, radians. */
    private fun turned(camera: GlobeCamera, dt: Double, now: Double): Double {
        val before = camera.orientation
        camera.step(dt, now, reduceMotion = false)
        return 2 * acos(min(1.0, abs(before.dot(camera.orientation))))
    }

    private fun released(vx: Double, vy: Double = 0.0) = GlobeCamera().apply {
        keepsDrifting = true
        drag(40.0, 0.0, 0.0)
        dragging = true
        dragging = false
        flick(vx, vy, 0.0, reduceMotion = false)
    }

    @Test fun `the release speed carries over exactly`() {
        val camera = released(300.0, -120.0)
        val rate = turned(camera, 1 / 120.0, 1 / 120.0) * 120
        val thrown = sqrt(300.0 * 300 + 120.0 * 120) * GlobeCamera.FLICK_TURN
        assertEquals(thrown, rate, thrown * 0.02)
    }

    @Test fun `a gentle let go never stops or waits`() {
        // Slower than the old 350 dp/s floor, which stopped it dead.
        val camera = released(120.0)
        for (i in 1..(120 * 6)) {
            val now = i / 120.0
            assertTrue("stopped at ${now}s", turned(camera, 1 / 120.0, now) > 0)
            // Within two seconds it is turning at the drift to the eye.
            if (i == 240) assertTrue(camera.spin.length < GlobeCamera.DRIFT_SPEED * 0.1)
        }
        assertTrue(camera.spin.isZero)
        assertEquals(GlobeCamera.DRIFT_SPEED, camera.drift, 0.0)
    }

    @Test fun `even a still let go eases straight into the drift`() {
        val camera = released(0.0)
        var last = 0.0
        for (i in 1..240) {
            val step = turned(camera, 1 / 120.0, i / 120.0)
            assertTrue(step > 0)
            assertTrue("the turn should only speed up into the drift", step >= last - 1e-9)
            last = step
        }
    }

    @Test fun `the drift turns the way it was thrown`() {
        val left = released(-900.0)
        val right = released(900.0)
        for (i in 1..(120 * 8)) {
            left.step(1 / 120.0, i / 120.0, reduceMotion = false)
            right.step(1 / 120.0, i / 120.0, reduceMotion = false)
        }
        assertEquals(-GlobeCamera.DRIFT_SPEED, left.drift, 0.0)
        assertEquals(GlobeCamera.DRIFT_SPEED, right.drift, 0.0)
        assertTrue(left.spin.isZero)
        // A straight up-and-down throw keeps the way it had.
        left.flick(0.0, 900.0, 8.0, reduceMotion = false)
        assertEquals(-GlobeCamera.DRIFT_SPEED, left.drift, 0.0)
    }

    @Test fun `the speed only ever falls toward the drift`() {
        // No dip below the drift and back: one smooth slow-down.
        val camera = released(1500.0)
        var last = Double.POSITIVE_INFINITY
        for (i in 1..(120 * 6)) {
            val step = turned(camera, 1 / 120.0, i / 120.0)
            assertTrue(step <= last + 1e-9)
            assertTrue(step * 120 >= GlobeCamera.DRIFT_SPEED * 0.999)
            last = step
        }
    }

    @Test fun `a hard throw glides further and longer than a gentle one`() {
        fun glide(vx: Double): Pair<Double, Double> {
            val camera = released(vx)
            var angle = 0.0
            var settled = 0.0
            for (i in 1..(120 * 10)) {
                val now = i / 120.0
                angle += turned(camera, 1 / 120.0, now)
                if (!camera.spin.isZero) settled = now
            }
            return angle to settled
        }
        val hard = glide(2000.0)
        val gentle = glide(300.0)
        assertTrue(hard.first > gentle.first * 2)
        assertTrue(hard.second > gentle.second)
    }

    @Test fun `with spinning off a throw still glides but ends still`() {
        val camera = GlobeCamera().apply { keepsDrifting = true; drifts = false }
        camera.flick(900.0, 0.0, 0.0, reduceMotion = false)
        var moved = 0.0
        var now = 0.0
        for (i in 1..(30 * 10)) { now = i / 30.0; moved += turned(camera, 1 / 30.0, now) }
        assertTrue(moved > 0.5)
        assertEquals(0.0, camera.drift, 0.0)
        assertFalse(camera.wantsFrames(now, reduceMotion = false))
    }

    @Test fun `a pinch still waits before the drift`() {
        // Only a let-go starts the drift at once; zooming waits as before.
        val camera = GlobeCamera()
        camera.touch(0.0)
        var i = 1
        while (i / 120.0 < GlobeCamera.DRIFT_AFTER - 0.1) {
            assertEquals(0.0, turned(camera, 1 / 120.0, i / 120.0), 0.0)
            i++
        }
    }
}
