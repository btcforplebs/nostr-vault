package com.nostrvault.relay

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RelayIdentityTest {

    @Test
    fun `the embedded relay's NIP-11 is ours`() {
        // Served by the app's relay on 127.0.0.1:3355 (emulator, 2026-10-26).
        val nip11 = """{"name":"Nostr Vault Outbox","description":"Outbox relay","pubkey":"","contact":"","supported_nips":[1,11,40,42,70,86,50,9,45,77],"software":"https://github.com/barrydeen/haven","version":"(devel)","icon":"","banner":""}"""
        assertTrue(RelayIdentity.isOurs(nip11))
    }

    @Test
    fun `another relay app on the port is not ours`() {
        assertFalse(RelayIdentity.isOurs("""{"name":"Citrine","software":"https://github.com/greenart7c3/Citrine","version":"1.0"}"""))
        assertFalse(RelayIdentity.isOurs("""{"name":"Some relay"}"""))
    }

    @Test
    fun `a non-relay answer is not ours`() {
        assertFalse(RelayIdentity.isOurs(""))
        assertFalse(RelayIdentity.isOurs("<html>Please use a Nostr client</html>"))
        assertFalse(RelayIdentity.isOurs("[]"))
    }
}
