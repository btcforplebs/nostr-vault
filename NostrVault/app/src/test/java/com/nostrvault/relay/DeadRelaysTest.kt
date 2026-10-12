package com.nostrvault.relay

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * nos.lol, nostr.mom and offchain.pub stopped answering (2026-10-12). They are
 * out of every default, and a saved config that still names them loses them
 * once, on load.
 */
class DeadRelaysTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val dead = listOf("wss://nos.lol", "wss://nostr.mom", "wss://offchain.pub")

    @Test
    fun `no default names a dead relay`() {
        val config = HavenConfig()
        val lists = listOf(
            config.inboxRelays.orEmpty(), config.feedRelays.orEmpty(), config.activeInboxRelays,
            config.activeFeedRelays, config.readRelays, config.dmRelays, config.dmInboxRelays,
            config.blastrRelays, config.importSeedRelays, config.activeSearchRelays,
            RelayConfiguration.FALLBACK_RELAYS, RelayConfiguration.FALLBACK_WRITE_RELAYS,
            RelayMatrix.wellKnownRelays, HavenConfig.DEFAULT_READ_RELAYS, HavenConfig.DEFAULT_DM_RELAYS,
        )
        for (list in lists) assertTrue(list.toString(), list.none(DeadRelays::isDead))
    }

    /** Several features ask only the first three read relays, so all three must be alive. */
    @Test
    fun `the first three read relays are live ones`() {
        assertEquals(
            listOf("wss://relay.primal.net", "wss://relay.damus.io", "wss://relay.btcforplebs.com"),
            HavenConfig().readRelays.take(3),
        )
    }

    @Test
    fun `isDead matches on the host in any spelling`() {
        assertTrue(DeadRelays.isDead("wss://nos.lol"))
        assertTrue(DeadRelays.isDead("WSS://NOS.LOL/"))
        assertTrue(DeadRelays.isDead(" wss://nostr.mom:443/path "))
        assertTrue(DeadRelays.isDead("wss://offchain.pub"))
        assertFalse(DeadRelays.isDead("wss://relay.damus.io"))
        assertFalse(DeadRelays.isDead("wss://nos.lol.example.com"))
    }

    @Test
    fun `a saved config loses the dead relays from every list`() {
        val saved = """{"ownerNpub":"npub1owner",
            "inboxRelays":["wss://relay.primal.net","wss://nos.lol","wss://nostr.mom","wss://relay.btcforplebs.com"],
            "feedRelays":["wss://nos.lol/","wss://relay.primal.net"],
            "dmRelays":["wss://relay.primal.net","wss://nos.lol","wss://relay.btcforplebs.com"],
            "blastrRelays":["wss://offchain.pub","wss://relay.damus.io"],
            "importSeedRelays":["wss://nostr.mom","wss://relay.primal.net"],
            "searchRelays":["wss://relay.nostr.band","wss://nos.lol"],
            "blockedRelays":["wss://nos.lol"]}"""
        val config = DeadRelays.dropping(json.decodeFromString(HavenConfig.serializer(), saved))
        assertEquals(listOf("wss://relay.primal.net", "wss://relay.btcforplebs.com"), config.inboxRelays)
        assertEquals(listOf("wss://relay.primal.net"), config.feedRelays)
        assertEquals(listOf("wss://relay.primal.net", "wss://relay.btcforplebs.com"), config.dmRelays)
        assertEquals(listOf("wss://relay.damus.io"), config.blastrRelays)
        assertEquals(listOf("wss://relay.primal.net"), config.importSeedRelays)
        assertEquals(listOf("wss://relay.nostr.band"), config.searchRelays)
        // Blocking a dead relay is still a choice.
        assertEquals(listOf("wss://nos.lol"), config.blockedRelays)
    }

    /** A user whose only read relay was nos.lol is not left with none. */
    @Test
    fun `a list the pruning would empty goes back to its default`() {
        val config = DeadRelays.dropping(HavenConfig(
            feedRelays = dead, inboxRelays = dead, dmRelays = dead, blastrRelays = dead,
            importSeedRelays = dead, searchRelays = dead,
        ))
        assertEquals(HavenConfig.DEFAULT_READ_RELAYS, config.feedRelays)
        assertEquals(HavenConfig.DEFAULT_READ_RELAYS, config.inboxRelays)
        assertEquals(HavenConfig.DEFAULT_DM_RELAYS, config.dmRelays)
        assertEquals(RelayConfiguration.FALLBACK_WRITE_RELAYS, config.blastrRelays)
        assertEquals(HavenConfig().importSeedRelays, config.importSeedRelays)
        assertNull("search goes back to 'defaults'", config.searchRelays)
    }

    @Test
    fun `a config without dead relays is returned as is`() {
        val config = HavenConfig(feedRelays = listOf("wss://relay.damus.io"), inboxRelays = null, searchRelays = null)
        assertSame(config, DeadRelays.dropping(config))
        // An emptied-on-purpose list stays empty.
        assertEquals(emptyList<String>(), DeadRelays.dropping(HavenConfig(feedRelays = emptyList())).feedRelays)
    }

    /** As ConfigStore saves it: equal-to-default fields are left out, so the new defaults apply to them. */
    @Test
    fun `a config that never set its relay lists gets the new defaults`() {
        val old = json.decodeFromString(HavenConfig.serializer(), """{"ownerNpub":"npub1owner"}""")
        assertEquals(HavenConfig.DEFAULT_READ_RELAYS, old.readRelays)
        assertEquals(HavenConfig.DEFAULT_DM_RELAYS, old.dmRelays)
    }
}
