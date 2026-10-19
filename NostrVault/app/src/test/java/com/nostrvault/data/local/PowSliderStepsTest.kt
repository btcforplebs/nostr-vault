package com.nostrvault.data.local

import org.junit.Assert.assertEquals
import org.junit.Test

class PowSliderStepsTest {
    @Test fun sliderMovesOneBitAtATime() {
        val stops = PowPreferences.SLIDER_STEPS + 2 // the two ends plus the steps between
        val width = (PowPreferences.MAX_DIFFICULTY - PowPreferences.MIN_DIFFICULTY).toDouble() / (stops - 1)
        assertEquals(1.0, width, 0.0)
        assertEquals(23, PowPreferences.SLIDER_STEPS)
    }
}
