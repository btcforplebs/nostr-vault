package com.nostrvault.ui.screens

import com.nostrvault.relay.HavenConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Create an account's starter servers: this device's Read relays, the five read servers on a new install. */
class StarterRelaysTest {

    @Test
    fun `a new install's starter list is the five read servers`() {
        val list = StarterRelays.from(HavenConfig.newInstall().activeFeedRelays)
        assertEquals(
            setOf("wss://relay.primal.net", "wss://relay.damus.io", "wss://relay.snort.social", "wss://relay.btcforplebs.com", "wss://nostr-pub.wellorder.net"),
            list.toSet(),
        )
        assertEquals(5, list.size)
    }

    @Test
    fun `starts from the public read relays, once each`() {
        val list = StarterRelays.from(listOf("wss://relay.primal.net", "ws://127.0.0.1:4869", "wss://relay.primal.net", "wss://Relay.Primal.net/", "wss://relay.btcforplebs.com"))
        assertEquals(listOf("wss://relay.primal.net", "wss://relay.btcforplebs.com"), list)
    }

    @Test
    fun `home network and ws relays never go on the public list`() {
        assertEquals(listOf("wss://relay.snort.social"), StarterRelays.from(listOf("ws://relay.example.com", "wss://192.168.1.4:4869", "wss://box.local", "wss://relay.snort.social")))
    }

    @Test
    fun `the published tags are the starter servers`() {
        assertEquals(
            listOf(listOf("r", "wss://relay.btcforplebs.com"), listOf("r", "wss://relay.damus.io")),
            StarterRelays.tags(listOf("wss://relay.btcforplebs.com", "wss://relay.damus.io")),
        )
        assertTrue(StarterRelays.tags(listOf("ws://127.0.0.1:4869")).isEmpty())
    }

    private val key = "a".repeat(64)
    private val recommended = StarterRelays.from(HavenConfig.newInstall().activeFeedRelays)

    @Test
    fun `nothing confirmed publishes nothing`() {
        assertNull(StarterRelays.finishTags(null, key))
    }

    @Test
    fun `the confirmed list is what goes out`() {
        val picks = StarterRelays.add(StarterRelays.remove(recommended, "wss://relay.damus.io"), "nos.lol")!!
        val tags = StarterRelays.finishTags(StarterRelays.Confirmed(key, picks), key)!!
        assertTrue(tags.any { it[1] == "wss://nos.lol" })
        assertTrue(tags.none { it[1] == "wss://relay.damus.io" })
        assertEquals(picks.size, tags.size)
    }

    @Test
    fun `a list confirmed for another key does not count`() {
        assertNull(StarterRelays.finishTags(StarterRelays.Confirmed("b".repeat(64), recommended), key))
    }

    @Test
    fun `an address without a scheme becomes wss, ws and home servers are refused`() {
        assertEquals("wss://nos.lol", StarterRelays.normalize("  nos.lol/ "))
        assertEquals("wss://relay.example.com", StarterRelays.normalize("wss://relay.example.com"))
        assertNull(StarterRelays.normalize("ws://relay.example.com"))
        assertNull(StarterRelays.normalize("127.0.0.1:4869"))
        assertNull(StarterRelays.normalize("not a relay"))
        assertNull(StarterRelays.normalize(""))
    }

    @Test
    fun `adding a server already on the list keeps it once`() {
        val list = listOf("wss://relay.primal.net")
        assertEquals(list, StarterRelays.add(list, "wss://Relay.Primal.net/"))
        assertNull(StarterRelays.add(list, "ws://x.example"))
    }

    @Test
    fun `remove matches the same server written differently`() {
        assertEquals(emptyList<String>(), StarterRelays.remove(listOf("wss://relay.primal.net"), "wss://Relay.Primal.net/"))
    }
}
