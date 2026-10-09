package com.nostrvault.relay

import org.junit.Assert.assertEquals
import org.junit.Test

/** Kind 10002 is the Read and Write relays, with the owner's own relay locked in. */
class PublicRelayListTest {

    @Test
    fun `both lists have no marker, one list is marked`() {
        val tags = PublicRelayList.tags(
            ownRelays = emptyList(),
            read = listOf("wss://both.example", "wss://r.example"),
            write = listOf("wss://both.example/", "wss://w.example"),
        )
        assertEquals(
            listOf(listOf("r", "wss://both.example"), listOf("r", "wss://r.example", "read"), listOf("r", "wss://w.example", "write")),
            tags,
        )
    }

    @Test
    fun `own relay leads unmarked so it stays in Write`() {
        val tags = PublicRelayList.tags(
            ownRelays = listOf("wss://vault.example.com", ""),
            read = listOf("wss://vault.example.com"),
            write = listOf("wss://w.example"),
        )
        assertEquals(listOf(listOf("r", "wss://vault.example.com"), listOf("r", "wss://w.example", "write")), tags)
    }

    @Test
    fun `unreachable relays are left out`() {
        val tags = PublicRelayList.tags(
            ownRelays = listOf("wss://192.168.1.20:3355"),
            read = listOf("ws://127.0.0.1:3355", "wss://mac.local", "https://x.example", "wss://ok.example"),
            write = emptyList(),
        )
        assertEquals(listOf(listOf("r", "wss://ok.example", "read")), tags)
    }

    @Test
    fun `config lists the Haven relay, then the roles`() {
        val config = HavenConfig(ownerNpub = "npub1owner").copy(
            macRelayURL = "https://vault.example.com",
            feedRelays = listOf("wss://r.example"),
            blastrRelays = listOf("wss://w.example"),
        )
        assertEquals(
            listOf(listOf("r", "wss://vault.example.com"), listOf("r", "wss://r.example", "read"), listOf("r", "wss://w.example", "write")),
            config.publicRelayListTags,
        )
    }

    @Test
    fun `the wizard inbox list is the Read list until a feed list is set`() {
        val config = HavenConfig(ownerNpub = "npub1owner").copy(
            inboxRelays = listOf("wss://in.example"),
            feedRelays = null,
            blastrRelays = listOf("wss://in.example"),
        )
        assertEquals(listOf(listOf("r", "wss://in.example")), config.publicRelayListTags)
    }
}
