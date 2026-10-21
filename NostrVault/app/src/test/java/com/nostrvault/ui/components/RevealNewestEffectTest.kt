package com.nostrvault.ui.components

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** When a newest-first list scrolls back to its top (the Vault tab's lists). */
class RevealNewestEffectTest {

    @Test fun rowsAboveTheOldFirstAreAPrepend() {
        assertTrue(isPrepend("b", listOf("a", "b", "c")))
        assertTrue(isPrepend("c", listOf("x", "y", "c", "d")))
    }

    @Test fun theSameFirstRowIsNot() {
        assertFalse(isPrepend("a", listOf("a", "b", "c")))
        // Older rows paged in at the bottom.
        assertFalse(isPrepend("a", listOf("a", "b", "c", "d")))
    }

    @Test fun aReloadThatDropsTheOldFirstIsNot() {
        // A filter or list switch replaces the rows; nothing to reveal.
        assertFalse(isPrepend("a", listOf("x", "y")))
    }

    @Test fun theFirstLoadAndAnEmptyListAreNot() {
        assertFalse(isPrepend(null, listOf("a", "b")))
        assertFalse(isPrepend("a", emptyList()))
    }
}
