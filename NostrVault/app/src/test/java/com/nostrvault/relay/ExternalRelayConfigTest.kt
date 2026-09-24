package com.nostrvault.relay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ExternalRelayConfigTest {

    private val embedded = HavenConfig(ownerNpub = "npub1owner")
    private val external = embedded.copy(
        useExternalRelay = true,
        externalRelayURL = "ws://127.0.0.1:4869",
        externalBlossomURL = "http://127.0.0.1:24242",
    )

    @Test
    fun `embedded relay keeps its sub-relay paths`() {
        assertEquals("ws://127.0.0.1:3355", embedded.nostrURL)
        assertEquals("ws://127.0.0.1:3355/inbox", embedded.localInboxURL)
        assertEquals("ws://127.0.0.1:3355/chat", embedded.localRelayURL("chat"))
        assertEquals("http://localhost:3355", embedded.localBlossomBaseURL)
    }

    @Test
    fun `external relay replaces the embedded one and collapses sub-relays`() {
        assertEquals("ws://127.0.0.1:4869", external.nostrURL)
        assertEquals("ws://127.0.0.1:4869", external.localInboxURL)
        assertEquals("ws://127.0.0.1:4869", external.localRelayURL("chat"))
        assertEquals("ws://127.0.0.1:4869", external.localRelayURL("feed"))
        assertEquals("http://127.0.0.1:24242", external.localBlossomBaseURL)
    }

    @Test
    fun `external mode without a Blossom URL has no local Blossom`() {
        assertNull(external.copy(externalBlossomURL = "").localBlossomBaseURL)
    }

    @Test
    fun `external mode with a blank relay URL has no relay`() {
        val blank = external.copy(externalRelayURL = "  ")
        assertNull(blank.nostrURL)
        assertNull(blank.localInboxURL)
    }

    @Test
    fun `no owner means no relay in either mode`() {
        assertNull(external.copy(ownerNpub = "").nostrURL)
    }

    @Test
    fun `relay URLs are normalized`() {
        assertEquals("ws://127.0.0.1:4869", normalizeExternalRelayURL(" 127.0.0.1:4869/ "))
        assertEquals("ws://localhost:4869", normalizeExternalRelayURL("ws://localhost:4869"))
        assertNull(normalizeExternalRelayURL("http://127.0.0.1:4869"))
        assertNull(normalizeExternalRelayURL(""))
    }

    @Test
    fun `only relays on this phone are accepted`() {
        // The local-relay clients trust only loopback, and cleartext is only
        // allowed there, so anything else would validate and never connect.
        assertNull(normalizeExternalRelayURL("wss://relay.example"))
        assertNull(normalizeExternalRelayURL("192.168.1.5:4869"))
        assertNull(normalizeExternalRelayURL("ws://127.0.0.1.evil.example:4869"))
    }

    @Test
    fun `Blossom URLs are normalized`() {
        assertEquals("http://127.0.0.1:24242", normalizeExternalBlossomURL("127.0.0.1:24242/"))
        assertNull(normalizeExternalBlossomURL("https://blossom.example"))
        assertNull(normalizeExternalBlossomURL("ws://127.0.0.1:4869"))
    }

    @Test
    fun `configs saved before this feature load in embedded mode`() {
        val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
        val old = json.decodeFromString<HavenConfig>("""{"ownerNpub":"npub1owner"}""")
        assertEquals(false, old.useExternalRelay)
        assertEquals("ws://127.0.0.1:3355", old.nostrURL)
    }
}
