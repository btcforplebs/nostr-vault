package com.nostrvault.ui.screens.dm

import org.junit.Assert.assertEquals
import org.junit.Test

/** The "Failed to Send" alert shows the error's own text, as iOS shows localizedDescription. */
class DMSendFailureTest {
    @Test fun usesTheErrorsText() {
        assertEquals("No private key", DMSendFailure.message(Exception("No private key")))
    }

    @Test fun trimsTheErrorsText() {
        assertEquals("Signing failed", DMSendFailure.message(Exception("  Signing failed\n")))
    }

    @Test fun fallsBackWhenTheErrorHasNoText() {
        assertEquals("The message could not be sent.", DMSendFailure.message(Exception()))
        assertEquals("The message could not be sent.", DMSendFailure.message(Exception("   ")))
    }

    @Test fun photoUploadFailureSaysSo() {
        assertEquals("Couldn't upload that photo.", DMSendFailure.message(DMPhotoUploadException()))
    }
}
