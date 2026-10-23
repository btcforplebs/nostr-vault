package com.nostrvault.ui.navigation

import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A nostrvault://mediapaste link can be fired by any app or web page, so it never uploads the clipboard by itself:
 * the gallery asks first (Tron, 3.0.0 42 pre-flight).
 */
class PendingMediaPasteTest {
    @After fun tearDown() {
        PendingMediaPaste.consume()
        PendingMediaPaste.cancel()
    }

    @Test fun `a link opens the confirm and does not paste by itself`() {
        PendingMediaPaste.request()
        assertTrue(PendingMediaPaste.consume())
        assertTrue(PendingMediaPaste.awaitingConfirm.value)
        assertFalse("taken once", PendingMediaPaste.consume())
    }

    @Test fun `only Upload pastes, and only once`() {
        PendingMediaPaste.request()
        PendingMediaPaste.consume()
        assertTrue(PendingMediaPaste.confirm())
        assertFalse(PendingMediaPaste.awaitingConfirm.value)
        assertFalse("a second tap pastes nothing", PendingMediaPaste.confirm())
    }

    @Test fun `Cancel pastes nothing`() {
        PendingMediaPaste.request()
        PendingMediaPaste.consume()
        PendingMediaPaste.cancel()
        assertFalse(PendingMediaPaste.awaitingConfirm.value)
        assertFalse(PendingMediaPaste.confirm())
    }

    @Test fun `no link, no confirm`() {
        assertFalse(PendingMediaPaste.consume())
        assertFalse(PendingMediaPaste.awaitingConfirm.value)
        assertFalse(PendingMediaPaste.confirm())
    }
}
