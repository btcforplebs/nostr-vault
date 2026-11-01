package com.nostrvault.relay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The owner's own relay list (kind 10002) is the read and write relays: the
 * starter relays are only for an account with no list, and an edit made here
 * is kept until a newer list is published (Logen 2026-11-01). Same cases as
 * iOS OwnRelayListTests.
 */
class OwnRelayListTest {
    private val theirRead = listOf("wss://read.example.com", "wss://both.example.com")
    private val theirWrite = listOf("wss://write.example.com", "wss://both.example.com")
    private val now = 9_999L

    private fun adopt(config: HavenConfig, read: List<String> = theirRead, write: List<String> = theirWrite, at: Long) =
        OwnRelayList.adopting(config, read, write, at, now)

    @Test
    fun `a new install takes their list over the starters`() {
        val config = HavenConfig.newInstall()
        assertNull(config.relayListUpdatedAt)
        val adopted = adopt(config, at = 1_000)
        assertEquals(theirRead, adopted.feedRelays)
        assertEquals(theirWrite, adopted.blastrRelays)
        assertEquals(1_000L, adopted.relayListUpdatedAt)
        assertFalse(adopted.readRelays.contains("wss://relay.snort.social"))
        assertFalse(adopted.writeRelays.contains("wss://relay.snort.social"))
    }

    @Test
    fun `an upgrader still on the old defaults takes their list`() {
        // HavenConfig() is what a saved config without the keys reads back as.
        val adopted = adopt(HavenConfig(), at = 1_000)
        assertEquals(theirRead, adopted.feedRelays)
        assertEquals(theirWrite, adopted.blastrRelays)
        val oldDead = HavenConfig(feedRelays = listOf("wss://nos.lol", "wss://relay.primal.net", "wss://nostr.mom"))
        assertEquals(theirRead, adopt(oldDead, at = 1_000).feedRelays)
    }

    @Test
    fun `a newer list replaces an adopted one, an older or same one does not`() {
        val adopted = adopt(HavenConfig.newInstall(), at = 2_000)
        val newer = adopt(adopted, listOf("wss://new.example.com"), listOf("wss://new.example.com"), at = 3_000)
        assertEquals(listOf("wss://new.example.com"), newer.feedRelays)
        assertSame(adopted, adopt(adopted, listOf("wss://old.example.com"), listOf("wss://old.example.com"), at = 1_000))
        assertSame(adopted, adopt(adopted, listOf("wss://old.example.com"), listOf("wss://old.example.com"), at = 2_000))
    }

    @Test
    fun `an edit here is kept over an older published list and loses to a newer one`() {
        val mine = HavenConfig(feedRelays = listOf("wss://mine.example.com"), blastrRelays = listOf("wss://mine.example.com"),
            relayListUpdatedAt = 5_000)
        assertSame(mine, adopt(mine, at = 4_000))
        assertEquals(theirRead, adopt(mine, at = 6_000).feedRelays)
    }

    @Test
    fun `an upgrader with relays of its own keeps them and is stamped now`() {
        val mine = HavenConfig.DEFAULT_READ_RELAYS + "wss://mine.example.com"
        val config = HavenConfig(feedRelays = mine)
        val stamped = adopt(config, at = 1_000)
        assertEquals(mine, stamped.feedRelays)
        assertEquals(now, stamped.relayListUpdatedAt)
        // From then on, only a list published after that wins.
        assertEquals(mine, adopt(stamped, at = now).feedRelays)
        assertEquals(theirRead, adopt(stamped, at = now + 1).feedRelays)
    }

    @Test
    fun `unusable, blocked and dead relays are left out`() {
        val config = HavenConfig.newInstall().copy(blockedRelays = listOf("wss://blocked.example.com/"))
        val adopted = adopt(
            config,
            read = listOf("wss://read.example.com/", "wss://127.0.0.1:3355", "ws://plain.example.com", "wss://nos.lol",
                "wss://blocked.example.com", "wss://READ.example.com"),
            write = listOf("wss://write.example.com"), at = 1_000,
        )
        assertEquals(listOf("wss://read.example.com"), adopted.feedRelays)
        assertEquals(listOf("wss://write.example.com"), adopted.blastrRelays)
    }

    @Test
    fun `an empty side keeps what it had`() {
        val config = HavenConfig.newInstall()
        val adopted = adopt(config, read = emptyList(), write = listOf("wss://write.example.com"), at = 1_000)
        assertEquals(config.feedRelays, adopted.feedRelays)
        assertEquals(listOf("wss://write.example.com"), adopted.blastrRelays)
    }

    @Test
    fun `the haven relay or this phone in a list is not an edit`() {
        assertTrue(OwnRelayList.looksUnedited(
            HavenConfig.DEFAULT_READ_RELAYS + listOf("ws://192.168.1.20:3355", "wss://127.0.0.1:3355"),
            HavenConfig.DEFAULT_READ_RELAYS,
        ))
        assertFalse(OwnRelayList.looksUnedited(listOf("wss://mine.example.com"), emptyList()))
    }
}
