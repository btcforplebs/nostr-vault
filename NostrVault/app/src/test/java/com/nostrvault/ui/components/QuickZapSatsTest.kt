package com.nostrvault.ui.components

import org.junit.Assert.assertEquals
import org.junit.Test

class QuickZapSatsTest {
    @Test
    fun `a default under 1 sat zaps 1`() {
        assertEquals(1, quickZapSats(0))
        assertEquals(1, quickZapSats(-5))
    }

    @Test
    fun `a real default is sent as set`() {
        assertEquals(1, quickZapSats(1))
        assertEquals(21, quickZapSats(21))
        assertEquals(5_000, quickZapSats(5_000))
    }
}
