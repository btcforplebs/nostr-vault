package com.nostrvault.relay

import org.junit.Assert.assertEquals
import org.junit.Test

/** The AUTH `relay` tag must equal haven-go's ServiceURL (relayServiceURL), not the ws:// socket address. */
class VaultAuthTagTest {
    private val embedded = HavenConfig(ownerNpub = "npub1owner")

    @Test
    fun `embedded vault paths are signed as wss like the relay checks`() {
        assertEquals("wss://127.0.0.1:3355/lists", embedded.vaultAuthRelayTag(embedded.localRelayURL("lists")!!))
        assertEquals("wss://127.0.0.1:3355/private", embedded.vaultAuthRelayTag(embedded.localRelayURL("private")!!))
    }

    @Test
    fun `the main relay is signed without a trailing slash`() {
        assertEquals("wss://127.0.0.1:3355", embedded.vaultAuthRelayTag(embedded.localRelayURL("")!!))
    }

    @Test
    fun `a persisted wss relay URL gives the same tag`() {
        val c = embedded.copy(relayURL = "wss://127.0.0.1:3355/")
        assertEquals("wss://127.0.0.1:3355/lists", c.vaultAuthRelayTag(c.localRelayURL("lists")!!))
    }

    @Test
    fun `another port follows the configured relay`() {
        val c = embedded.copy(relayURL = "ws://127.0.0.1:4455", relayPort = 4455)
        assertEquals("wss://127.0.0.1:4455/lists", c.vaultAuthRelayTag(c.localRelayURL("lists")!!))
    }

    @Test
    fun `an onion host stays ws like haven-go getHTTPScheme`() {
        val c = embedded.copy(relayURL = "ws://abc.onion")
        assertEquals("ws://abc.onion/lists", c.vaultAuthRelayTag(c.localRelayURL("lists")!!))
    }

    @Test
    fun `an external relay and foreign urls pass through`() {
        val ext = embedded.copy(useExternalRelay = true, externalRelayURL = "ws://127.0.0.1:4869")
        assertEquals("ws://127.0.0.1:4869", ext.vaultAuthRelayTag(ext.localRelayURL("lists")!!))
        assertEquals("wss://relay.damus.io", embedded.vaultAuthRelayTag("wss://relay.damus.io"))
        assertEquals("ws://127.0.0.1:33550/lists", embedded.vaultAuthRelayTag("ws://127.0.0.1:33550/lists"))
    }

    @Test
    fun `no owner means no vault and the url passes through`() {
        val none = HavenConfig()
        assertEquals("ws://127.0.0.1:3355/lists", none.vaultAuthRelayTag("ws://127.0.0.1:3355/lists"))
    }
}
