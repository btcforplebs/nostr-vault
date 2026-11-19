package com.nostrvault.data.model

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Logen 7eee63d2: "stop flying thing when we pause spinning". While the WoT
 * globe's spin is paused no arrival flies, so the clock can sleep. Mirrors
 * HavenApp/MediaLogicTests/Tests/MediaLogicTests/GlobeSpinPauseTests.swift.
 */
class GlobeSpinPauseTest {
    private fun camera(touchedAt: Double) = GlobeCamera().apply { touch(touchedAt) }

    @Test fun spinningRightAfterATouchIsNotPaused() {
        assertFalse(camera(100.0).spinPaused(105.0))
    }

    @Test fun untouchedPastSleepAfterWithTheDriftStoppedIsPaused() {
        val c = camera(100.0)
        assertFalse(c.spinPaused(100 + GlobeCamera.SLEEP_AFTER - 0.1))
        assertTrue(c.spinPaused(100 + GlobeCamera.SLEEP_AFTER))
    }

    @Test fun stillEasingOutIsNotPausedYet() {
        val c = camera(0.0)
        c.drift = 0.01
        assertFalse("the drift is still slowing", c.spinPaused(100.0))
    }

    @Test fun aTouchResumes() {
        val c = camera(0.0)
        assertTrue(c.spinPaused(100.0))
        c.touch(100.0)
        assertFalse(c.spinPaused(100.5))
    }

    @Test fun anyMotionUnderAFingerIsNotPaused() {
        val c = camera(0.0)
        c.dragging = true
        assertFalse(c.spinPaused(100.0))
        c.dragging = false
        c.spin = Vec3(0.0, 0.3, 0.0)
        assertFalse(c.spinPaused(100.0))
    }

    @Test fun spinningSwitchedOffIsPausedWhenStill() {
        val c = camera(100.0)
        c.drifts = false
        assertTrue(c.spinPaused(101.0))
    }

    @Test fun aGlobeThatKeepsDriftingNeverPauses() {
        val c = camera(0.0)
        c.keepsDrifting = true
        assertFalse(c.spinPaused(10_000.0))
    }
}
