package com.nostrvault.service

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Import media into this device's own vault: a keyless vault (npub only) goes
 * in-process and never asks a signer; a keyed vault signs once, as before.
 */
class OwnVaultAuthTest {
    @Test
    fun `a keyless vault never asks the signer`() = runBlocking {
        var asked = 0
        val auth = OwnVaultAuth.of(keyless = true) { asked++; "signed" }
        assertEquals(OwnVaultAuth.Keyless, auth)
        assertEquals(0, asked)
    }

    @Test
    fun `a keyed vault signs one header, unchanged`() = runBlocking {
        var asked = 0
        val auth = OwnVaultAuth.of(keyless = false) { asked++; "base64header" }
        assertEquals(OwnVaultAuth.Signed("base64header"), auth)
        assertEquals(1, asked)
    }

    @Test
    fun `a keyed vault whose signer gives nothing stops, as before`() = runBlocking {
        assertNull(OwnVaultAuth.of(keyless = false) { "" })
    }
}
