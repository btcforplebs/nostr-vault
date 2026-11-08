package com.nostrvault.relay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The vault reads only the owner's own relay list (Logen 2026-11-08). Twin of iOS VaultSeedRelaysTests. */
class VaultSeedRelaysTest {
    private val read = listOf("wss://relay.primal.net", "wss://my.relay/")
    private val write = listOf("wss://my.relay", "wss://relay.snort.social")

    @Test fun `vault seeds are read then write then picks, deduplicated`() {
        assertEquals(
            listOf("wss://relay.primal.net", "wss://my.relay/", "wss://relay.snort.social", "wss://picked.example"),
            VaultSeedRelays.vaultSeeds(read, write, listOf("wss://picked.example", "WSS://RELAY.PRIMAL.NET")),
        )
    }

    @Test fun `a new config reads only its own list`() {
        val config = HavenConfig.newInstall()
        assertEquals(emptyList<String>(), config.importSeedRelays)
        assertEquals((config.feedRelays!! + config.blastrRelays).toSet(), config.vaultSeedRelays.toSet())
        val mine = config.copy(feedRelays = listOf("wss://only.mine"), blastrRelays = listOf("wss://only.mine/"))
        assertEquals(listOf("wss://only.mine"), mine.vaultSeedRelays)
        assertTrue(mine.vaultSeedRelays.none { "damus" in it || "wellorder" in it || "ditto" in it })
    }

    @Test fun `old defaults are dropped on load`() {
        val oldAndroid = HavenConfig.newInstall().copy(
            importSeedRelays = listOf("wss://relay.primal.net", "wss://relay.btcforplebs.com", "wss://nostr-pub.wellorder.net"),
            feedRelays = listOf("wss://only.mine"), blastrRelays = listOf("wss://only.mine"),
        )
        val migrated = VaultSeedRelays.keepingOnlyPicks(oldAndroid)
        assertEquals(emptyList<String>(), migrated.importSeedRelays)
        assertEquals(listOf("wss://only.mine"), migrated.vaultSeedRelays)
    }

    @Test fun `the owner's picks survive`() {
        val saved = listOf("wss://relay.primal.net", "wss://picked.example", "wss://relay.damus.io")
        assertEquals(listOf("wss://picked.example", "wss://relay.damus.io"), VaultSeedRelays.chosenImportRelays(saved, read + write, ""))
    }
}
