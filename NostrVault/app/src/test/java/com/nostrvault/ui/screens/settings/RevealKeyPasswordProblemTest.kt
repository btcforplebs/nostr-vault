package com.nostrvault.ui.screens.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Settings' Reveal Private Key password gate (iOS RevealKeySheetView). */
class RevealKeyPasswordProblemTest {
    @Test fun rightPasswordReveals() {
        assertNull(revealKeyPasswordProblem("hunter22", "hunter22"))
    }

    @Test fun wrongOrEmptyPasswordIsRefused() {
        assertEquals(REVEAL_WRONG_PASSWORD, revealKeyPasswordProblem("hunter22", "hunter2"))
        assertEquals(REVEAL_WRONG_PASSWORD, revealKeyPasswordProblem("hunter22", "hunter22 "))
        assertEquals(REVEAL_WRONG_PASSWORD, revealKeyPasswordProblem("hunter22", "Hunter22"))
        assertEquals(REVEAL_WRONG_PASSWORD, revealKeyPasswordProblem("hunter22", ""))
    }

    @Test fun accountWithoutStoredPasswordNeverUnlocksHere() {
        assertEquals(REVEAL_NO_KEY, revealKeyPasswordProblem(null, "anything"))
        assertEquals(REVEAL_NO_KEY, revealKeyPasswordProblem(null, ""))
    }
}
