package com.nostrvault.ui.screens.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The default reaction comes from the full emoji picker now, typed emoji included. */
class DefaultReactionTest {
    @Test
    fun `a picked emoji is kept, trimmed`() {
        assertEquals("🦙", defaultReactionFrom(" 🦙 "))
        assertEquals("+", defaultReactionFrom("+"))
    }

    @Test
    fun `a blank pick changes nothing`() {
        assertNull(defaultReactionFrom(""))
        assertNull(defaultReactionFrom("  "))
    }
}
