package com.nostrvault.relay

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The read and write relay roles every feature asks for, instead of each one
 * building its own "configured list, or primal + nos.lol" fallback.
 */
class RelayRolesTest {

    private val base = HavenConfig(ownerNpub = "npub1owner")

    @Test
    fun `read relays are the feed relays`() {
        val config = base.copy(feedRelays = listOf("wss://a.example", "wss://b.example"), blastrRelays = listOf("wss://w.example"))
        assertEquals(listOf("wss://a.example", "wss://b.example"), config.readRelays)
    }

    @Test
    fun `write relays are the broadcast relays`() {
        val config = base.copy(feedRelays = listOf("wss://a.example"), blastrRelays = listOf("wss://w.example"))
        assertEquals(listOf("wss://w.example"), config.writeRelays)
    }

    @Test
    fun `an emptied feed list falls back`() {
        val config = base.copy(feedRelays = emptyList())
        assertEquals(RelayConfiguration.FALLBACK_RELAYS, config.readRelays)
    }

    @Test
    fun `the Haven relay leads both roles`() {
        val config = base.copy(
            macRelayURL = "https://mac.example.com",
            feedRelays = emptyList(),
            blastrRelays = listOf("wss://w.example"),
        )
        assertEquals(listOf("wss://mac.example.com"), config.readRelays)
        assertEquals(listOf("wss://mac.example.com", "wss://w.example"), config.writeRelays)
    }
}
