package com.nostrvault.ui.screens

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** iOS ComposeView.handleCancelTapped: only text worth keeping asks to be saved. */
class ComposeDraftPromptTest {

    @Test
    fun `empty or whitespace closes without asking`() {
        assertFalse(composeNeedsDraftPrompt(""))
        assertFalse(composeNeedsDraftPrompt("   \n  "))
    }

    @Test
    fun `a short single word closes without asking`() {
        assertFalse(composeNeedsDraftPrompt("gm"))
        assertFalse(composeNeedsDraftPrompt("  1234567890  "))
    }

    @Test
    fun `two words ask`() {
        assertTrue(composeNeedsDraftPrompt("gm all"))
    }

    @Test
    fun `one long word asks`() {
        assertTrue(composeNeedsDraftPrompt("12345678901"))
    }
}
