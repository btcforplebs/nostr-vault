package com.nostrvault.ui.screens.settings

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A copied nsec comes off the clipboard after a minute, but something the
 * user copied since is never wiped (Android review K3).
 */
class SecretKeyClipTest {
    private val nsec = "nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"

    @Test fun theKeyStillOnTheClipboardIsCleared() {
        assertTrue(shouldClearCopiedSecret(nsec, nsec, replaced = false))
        assertTrue(shouldClearCopiedSecret(nsec, nsec, replaced = true))
    }

    @Test fun somethingCopiedSinceIsKept() {
        assertFalse(shouldClearCopiedSecret("a shopping list", nsec, replaced = false))
        assertFalse(shouldClearCopiedSecret("a shopping list", nsec, replaced = true))
    }

    @Test fun unreadableClipboardIsClearedOnlyWhenNothingChanged() {
        assertTrue(shouldClearCopiedSecret(null, nsec, replaced = false))
        assertFalse(shouldClearCopiedSecret(null, nsec, replaced = true))
    }
}
