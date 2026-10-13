package com.nostrvault.ui.components

import org.junit.Assert.assertEquals
import org.junit.Test

/** The score on the 🔥 line reads like iOS PopularRankLine.formatted. */
class PopularRankLineTest {
    @Test
    fun `scores under a thousand are whole numbers, from a thousand up they are k`() {
        assertEquals("0", formatPopularScore(0.2))
        assertEquals("999", formatPopularScore(999.0))
        assertEquals("1.0k", formatPopularScore(1000.0))
        assertEquals("12.3k", formatPopularScore(12_340.0))
    }
}
