package com.nostrvault.ui.screens.profile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PullToEditStateTest {
    @Test fun armsPastTheMarkAtHalfRate() {
        val state = PullToEditState(thresholdPx = 100f)
        assertEquals(150f, state.drag(150f), 0.01f)
        assertFalse(state.isArmed)
        state.drag(50f)
        assertTrue(state.isArmed)
        assertEquals(1f, state.progress, 0.001f)
    }

    @Test fun pushingBackUpCancelsAndStopsAtZero() {
        val state = PullToEditState(thresholdPx = 100f)
        state.drag(240f)
        assertTrue(state.isArmed)
        state.drag(-60f)
        assertFalse(state.isArmed)
        // Only the 180px the pull still held is taken; the rest scrolls the list.
        assertEquals(-180f, state.drag(-500f), 0.01f)
        assertEquals(0f, state.distance, 0.001f)
    }
}
