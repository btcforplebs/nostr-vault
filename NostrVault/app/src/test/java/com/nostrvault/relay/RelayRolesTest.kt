package com.nostrvault.relay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The read and write relay roles every feature asks for, instead of each one
 * building its own "configured list, or primal + damus" fallback.
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
    fun `an emptied write list falls back`() {
        assertEquals(RelayConfiguration.FALLBACK_WRITE_RELAYS, base.copy(blastrRelays = emptyList()).writeRelays)
    }

    /** A new account's kind 10002 marks all five read servers write, so it writes to all five. */
    @Test
    fun `a new install writes to the five read relays`() {
        val config = HavenConfig.newInstall()
        assertEquals(HavenConfig.DEFAULT_READ_RELAYS, config.blastrRelays)
        assertEquals(5, config.blastrRelays.size)
        assertEquals(config.feedRelays, config.blastrRelays)
        assertTrue(config.publicRelayListTags.all { it.size == 2 })
    }

    /** Defaults are not written to config.json, so an old install that never set its broadcast list keeps three. */
    @Test
    fun `an old config without a broadcast list keeps the three`() {
        val old = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
            .decodeFromString(HavenConfig.serializer(), """{"ownerNpub":"npub1owner"}""")
        assertEquals(RelayConfiguration.FALLBACK_WRITE_RELAYS, old.blastrRelays)
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
