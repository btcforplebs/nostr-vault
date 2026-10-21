package com.nostrvault.ui.screens.settings

import com.nostrvault.setup.IdentityInput
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Settings' Import Private Key password rules (iOS ImportKeySheetView, setup's "I already use Nostr"). */
class ImportKeyProblemTest {
    private val nsec = IdentityInput.SecretKey("nsec1x")
    private val ncryptsec = IdentityInput.EncryptedSecretKey("ncryptsec1x")

    @Test fun ownerNsecNeedsEightCharactersTypedTwice() {
        assertEquals("Password must be at least 8 characters", importKeyProblem(nsec, "short", "short", newPassword = true))
        assertEquals("Passwords do not match", importKeyProblem(nsec, "longenough", "longenougH", newPassword = true))
        assertNull(importKeyProblem(nsec, "longenough", "longenough", newPassword = true))
    }

    @Test fun otherAccountNsecNeedsNoPassword() {
        assertNull(importKeyProblem(nsec, "", "", newPassword = false))
    }

    @Test fun ncryptsecOnlyNeedsItsPassword() {
        assertEquals("Enter the password for this key", importKeyProblem(ncryptsec, "", "", newPassword = true))
        assertNull(importKeyProblem(ncryptsec, "x", "", newPassword = true))
        assertNull(importKeyProblem(ncryptsec, "x", "", newPassword = false))
    }

    @Test fun anythingElseIsRefused() {
        assertEquals("Paste an nsec1… or ncryptsec1… key.", importKeyProblem(IdentityInput.PublicKey("npub1x"), "pw", "pw", newPassword = true))
    }
}
