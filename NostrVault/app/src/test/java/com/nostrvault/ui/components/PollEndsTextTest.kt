package com.nostrvault.ui.components

import org.junit.Assert.assertEquals
import org.junit.Test

/** A poll card's close time: minutes, hours, then days, rounded down. */
class PollEndsTextTest {
    private val now = 1_800_000_000L

    @Test fun `counts down in the largest whole unit`() {
        assertEquals("Ends in under a minute", pollEndsText(now + 59, now))
        assertEquals("Ends in 1m", pollEndsText(now + 60, now))
        assertEquals("Ends in 59m", pollEndsText(now + 3_599, now))
        assertEquals("Ends in 1h", pollEndsText(now + 3_600, now))
        assertEquals("Ends in 23h", pollEndsText(now + 86_399, now))
        assertEquals("Ends in 2d", pollEndsText(now + 2 * 86_400, now))
    }
}
