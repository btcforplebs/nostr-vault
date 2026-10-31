package com.nostrvault.ui.screens.settings

import org.junit.Assert.assertEquals
import org.junit.Test

/** The Accounts & Keys row's signer line, matching iOS AccountsSettingsView. */
class SigningModeLabelTest {

    @Test
    fun `a public-key-only account has no signing key`() {
        assertEquals("No signing key", signingModeLabel(mode = "local", hasBunker = false, hasLocalKey = false))
    }

    @Test
    fun `a stored key reads Local Key`() {
        assertEquals("Local Key", signingModeLabel(mode = "local", hasBunker = false, hasLocalKey = true))
    }

    @Test
    fun `remote and Amber signers keep their labels without a local key`() {
        assertEquals("Remote Signer", signingModeLabel(mode = "nip46", hasBunker = false, hasLocalKey = false))
        assertEquals("Remote Signer", signingModeLabel(mode = "local", hasBunker = true, hasLocalKey = false))
        assertEquals("Amber", signingModeLabel(mode = "amber", hasBunker = false, hasLocalKey = false))
    }
}
