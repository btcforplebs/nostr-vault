package com.nostrvault.relay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
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
    fun `relays off this phone need wss`() {
        // Cleartext is only allowed to loopback (network_security_config), so
        // a plain ws:// anywhere else would validate and never connect.
        assertEquals("wss://relay.example", normalizeExternalRelayURL("wss://relay.example/"))
        assertEquals("wss://relay.example:4848", normalizeExternalRelayURL("relay.example:4848"))
        assertEquals("wss://192.168.1.5:4869", normalizeExternalRelayURL("192.168.1.5:4869"))
        assertNull(normalizeExternalRelayURL("ws://192.168.1.5:4869"))
        assertNull(normalizeExternalRelayURL("ws://127.0.0.1.evil.example:4869"))
        assertNull(normalizeExternalRelayURL("ws://relay.example"))
    }

    @Test
    fun `onion and malformed addresses are refused`() {
        assertNull(normalizeExternalRelayURL("wss://abcdefghijklmnop.onion"))
        assertNull(normalizeExternalRelayURL("abcdefghijklmnop.onion:4869"))
        assertNull(normalizeExternalRelayURL("wss://relay example"))
        assertNull(normalizeExternalBlossomURL("https://x.onion"))
    }

    @Test
    fun `Blossom URLs are normalized`() {
        assertEquals("http://127.0.0.1:24242", normalizeExternalBlossomURL("127.0.0.1:24242/"))
        assertEquals("https://blossom.example", normalizeExternalBlossomURL("https://blossom.example"))
        assertEquals("https://mac.example", normalizeExternalBlossomURL("mac.example"))
        assertNull(normalizeExternalBlossomURL("http://blossom.example"))
        assertNull(normalizeExternalBlossomURL("ws://127.0.0.1:4869"))
    }

    @Test
    fun `a relay off this phone is used as given`() {
        val mac = external.copy(
            externalRelayURL = "wss://relay.mac.example",
            externalBlossomURL = "https://relay.mac.example",
        )
        assertEquals("wss://relay.mac.example", mac.nostrURL)
        assertEquals("wss://relay.mac.example", mac.localRelayURL("chat"))
        assertEquals("https://relay.mac.example", mac.localBlossomBaseURL)
    }

    @Test
    fun `configs saved before this feature load in embedded mode`() {
        val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
        val old = json.decodeFromString<HavenConfig>("""{"ownerNpub":"npub1owner"}""")
        assertEquals(false, old.useExternalRelay)
        assertEquals("ws://127.0.0.1:3355", old.nostrURL)
    }

    @Test
    fun `private network addresses are told apart from public ones`() {
        for (u in listOf(
            "http://127.0.0.1:3355", "https://localhost", "https://192.168.1.5", "https://10.0.0.2:443",
            "https://172.20.1.1", "https://100.101.102.103", "https://mac.local", "https://mac.tail1234.ts.net",
        )) assertEquals(u, true, isPrivateNetworkURL(u))
        for (u in listOf(
            "https://relay.mac.example", "https://10.example.com", "https://172.32.0.1", "https://8.8.8.8",
        )) assertEquals(u, false, isPrivateNetworkURL(u))
    }

    @Test
    fun `only LAN IP literals get the self-signed client`() {
        assertTrue(com.nostrvault.data.remote.WebSocketClient.isLocalOrLanHost("wss://192.168.1.5:4869"))
        assertTrue(com.nostrvault.data.remote.WebSocketClient.isLocalOrLanHost("wss://10.0.0.2"))
        assertFalse(com.nostrvault.data.remote.WebSocketClient.isLocalOrLanHost("wss://10.example.com"))
        assertFalse(com.nostrvault.data.remote.WebSocketClient.isLocalOrLanHost("wss://relay.example"))
    }
}
