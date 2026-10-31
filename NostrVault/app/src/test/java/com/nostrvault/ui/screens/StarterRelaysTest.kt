package com.nostrvault.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Create an account's starter servers: the public broadcast relays, never damus. */
class StarterRelaysTest {

    @Test
    fun `starts from the public broadcast relays, once each`() {
        val list = StarterRelays.from(listOf("wss://relay.primal.net", "ws://127.0.0.1:4869", "wss://relay.primal.net", "wss://relay.btcforplebs.com"))
        assertEquals(listOf("wss://relay.primal.net", "wss://relay.btcforplebs.com"), list)
    }

    @Test
    fun `damus is never on the starter list, however it is spelled`() {
        val list = StarterRelays.from(listOf("wss://relay.btcforplebs.com", "wss://relay.damus.io", "wss://Relay.Damus.io/"))
        assertEquals(listOf("wss://relay.btcforplebs.com"), list)
    }

    @Test
    fun `the published tags are the starter servers`() {
        assertEquals(
            listOf(listOf("r", "wss://relay.btcforplebs.com"), listOf("r", "wss://relay.snort.social")),
            StarterRelays.tags(listOf("wss://relay.btcforplebs.com", "wss://relay.damus.io", "wss://relay.snort.social")),
        )
        assertTrue(StarterRelays.tags(listOf("wss://relay.damus.io")).isEmpty())
    }
}
