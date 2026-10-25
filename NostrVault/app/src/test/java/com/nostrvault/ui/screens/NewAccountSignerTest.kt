package com.nostrvault.ui.screens

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** New to Nostr setup: its kind 0 and 10002 go out only if the generated key signed them (iOS 5cd4b5e9). */
class NewAccountSignerTest {
    private val generated = "a".repeat(64)

    @Test fun theNewKeyPasses() {
        assertTrue(signedByNewKey(generated, generated))
        assertTrue(signedByNewKey(generated.uppercase(), generated))
    }

    @Test fun anotherAccountOrNothingIsDropped() {
        assertFalse(signedByNewKey("b".repeat(64), generated))
        assertFalse(signedByNewKey(null, generated))
        assertFalse(signedByNewKey("", generated))
    }
}
