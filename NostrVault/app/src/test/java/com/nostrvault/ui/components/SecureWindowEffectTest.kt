package com.nostrvault.ui.components

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** FLAG_SECURE while an nsec is on screen (bug hunt 2026-11-05 #10). */
class SecureWindowEffectTest {
    @Test
    fun `the first holder sets the flag and only the last one clears it`() {
        val holders = SecureHolders()
        assertTrue(holders.acquire())   // revealed key: set
        assertFalse(holders.acquire())  // Add Account field with an nsec too: already set
        assertFalse(holders.release())  // the field is cleared: the key is still shown
        assertTrue(holders.release())   // the key is hidden: clear
        assertFalse(holders.release())  // an extra release does not go negative
        assertTrue(holders.acquire())
    }

    @Test
    fun `only an nsec counts as a secret in a field`() {
        assertEquals(
            listOf(true, true, false, false, false),
            listOf(" nsec1abc", "NSEC1ABC", "npub1abc", "ncryptsec1abc", "").map(::showsSecretKey),
        )
    }
}
