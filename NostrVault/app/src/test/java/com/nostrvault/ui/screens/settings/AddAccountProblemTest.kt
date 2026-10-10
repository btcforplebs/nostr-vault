package com.nostrvault.ui.screens.settings

import com.nostrvault.setup.IdentityInput
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** What Add Account takes: an npub, an nsec, or a NIP-49 ncryptsec. */
class AddAccountProblemTest {

    @Test
    fun `keys and npubs are accepted`() {
        assertNull(addAccountProblem(IdentityInput.PublicKey("npub1abc")))
        assertNull(addAccountProblem(IdentityInput.SecretKey("nsec1abc")))
        assertNull(addAccountProblem(IdentityInput.EncryptedSecretKey("ncryptsec1abc")))
    }

    @Test
    fun `a hex key is sent back for its bech32 form`() {
        assertEquals("Paste the npub or nsec version of this key.", addAccountProblem(IdentityInput.HexKey))
    }

    @Test
    fun `anything else names the three shapes`() {
        assertEquals("Enter an npub, nsec or ncryptsec.", addAccountProblem(IdentityInput.Unrecognised))
        assertEquals("Enter an npub, nsec or ncryptsec.", addAccountProblem(IdentityInput.Nip05("a@b.c")))
    }
}
