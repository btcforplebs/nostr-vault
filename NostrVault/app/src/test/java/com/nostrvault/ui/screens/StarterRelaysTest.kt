package com.nostrvault.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Create an account's starter relay list: shown first, published only on Use. */
class StarterRelaysTest {

    @Test
    fun `starts from the public broadcast relays, once each`() {
        val list = StarterRelays.from(listOf("wss://relay.primal.net", "ws://127.0.0.1:4869", "wss://relay.primal.net", "wss://relay.btcforplebs.com"))
        assertEquals(listOf("wss://relay.primal.net", "wss://relay.btcforplebs.com"), list)
    }

    @Test
    fun `skip publishes nothing`() {
        assertTrue(StarterRelays.tags(listOf("wss://relay.primal.net"), use = false).isEmpty())
    }

    @Test
    fun `use publishes exactly the edited list`() {
        var list = listOf("wss://relay.primal.net", "wss://relay.btcforplebs.com")
        list = StarterRelays.removing(list, "wss://relay.primal.net/")
        list = StarterRelays.adding(list, "nostr.land")!!
        assertEquals(listOf(listOf("r", "wss://relay.btcforplebs.com"), listOf("r", "wss://nostr.land")), StarterRelays.tags(list, use = true))
    }

    @Test
    fun `adding a private or malformed address is refused, a duplicate changes nothing`() {
        val list = listOf("wss://relay.primal.net")
        assertNull(StarterRelays.adding(list, "ws://192.168.1.4:4869"))
        assertNull(StarterRelays.adding(list, "not a relay"))
        assertEquals(list, StarterRelays.adding(list, "relay.primal.net"))
    }
}
