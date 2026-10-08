package com.nostrvault.setup

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The "I already use Nostr" field: what's pasted decides read-only vs
 *  can-post. Mirrors iOS IdentityInputTests. */
class IdentityInputTest {
    private val hex = "a".repeat(64)

    @Test fun publicKeysAreReadOnly() {
        for (raw in listOf("npub1abc", "  NPUB1ABC\n", "nostr:npub1abc")) {
            val input = IdentityInput.parse(raw)
            assertEquals(raw, IdentityInput.PublicKey("npub1abc"), input)
            assertFalse(input.canPost)
            assertEquals("browse", input.setupMode)
        }
    }

    @Test fun nip05IsReadOnly() {
        assertEquals(IdentityInput.Nip05("alice@example.com"), IdentityInput.parse("Alice@Example.com"))
        assertEquals(IdentityInput.Nip05("example.com"), IdentityInput.parse("example.com"))
        assertEquals("browse", IdentityInput.parse("_@example.com").setupMode)
    }

    @Test fun keysAndSignersCanPost() {
        assertEquals(IdentityInput.SecretKey("nsec1xyz"), IdentityInput.parse("nsec1xyz"))
        assertEquals(IdentityInput.SecretKey("nsec1xyz"), IdentityInput.parse("nostr:NSEC1XYZ"))
        assertEquals(IdentityInput.EncryptedSecretKey("ncryptsec1qq"), IdentityInput.parse("ncryptsec1qq"))
        val uri = "bunker://$hex?relay=wss://relay.example.com"
        val bunker = IdentityInput.parse(uri)
        assertEquals(IdentityInput.RemoteSigner(uri), bunker)
        for (input in listOf(IdentityInput.parse("nsec1xyz"), IdentityInput.parse("ncryptsec1qq"), bunker)) {
            assertTrue(input.canPost)
            assertEquals("full", input.setupMode)
        }
    }

    /** A raw hex key could be either kind; guessing "public" would put
     *  someone's private key on screen as their identity. */
    @Test fun rawHexIsRefused() {
        assertEquals(IdentityInput.HexKey, IdentityInput.parse(hex))
        assertEquals(IdentityInput.HexKey, IdentityInput.parse(hex.uppercase()))
        assertNull(IdentityInput.parse(hex).setupMode)
        assertFalse(IdentityInput.parse(hex).canPost)
    }

    @Test fun junkIsNotUsable() {
        for (raw in listOf(
            "", "   ", "hello", "@example.com", "alice@", "alice@example", "a b.com",
            "https://example.com", "bunker://notakey", "bunker://$hex", ".com", "example.", "nprofile1qqs",
        )) {
            assertNull(raw, IdentityInput.parse(raw).setupMode)
        }
        assertEquals(IdentityInput.Empty, IdentityInput.parse(""))
        assertNull(IdentityInput.parse("").hint)
        assertNotNull(IdentityInput.parse("hello").hint)
    }
}
