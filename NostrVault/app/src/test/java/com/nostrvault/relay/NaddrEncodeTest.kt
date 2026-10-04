package com.nostrvault.relay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The Shopstr link for a Marketplace listing is built from this naddr. */
class NaddrEncodeTest {
    private val pubkey = "a723805cda67251191c8786f4da58f797e6977582301354ba8e91bcb0342dc9c"
    private val dTag = "fe8beb74-d1ad-414d-bcbc-e980b4784e96"

    @Test fun `matches an independently computed naddr`() {
        // Computed with a separate Python bech32 implementation from the same
        // TLV (d tag, pubkey, kind 30018).
        assertEquals(
            "naddr1qqjxvefcvfjkyde594jrzcty956rzdry943xxcnr94jnjwpsvg6rwwp5v5unvq3q5u3cqhx6vuj3rywg0ph5mfv009lxja6cyvqn2jagaydukq6zmjwqxpqqqp65yr2u6j3",
            HavenBridge.encodeNaddr(dTag, pubkey, 30018),
        )
    }

    @Test fun `round-trips through the decoder`() {
        val naddr = HavenBridge.encodeNaddr(dTag, pubkey, 30402)!!
        assertEquals(
            com.nostrvault.data.model.QuoteRef.Coordinate(30402, pubkey, dTag),
            HavenBridge.decodeNaddr(naddr),
        )
    }

    @Test fun `rejects a bad pubkey`() {
        assertNull(HavenBridge.encodeNaddr(dTag, "abcd", 30018))
    }
}
