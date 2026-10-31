package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Logen 2026-10-22: each 10063 landed on one relay; it goes to every write relay the owner names. */
class ServerListRelaysTest {
    @Test
    fun `every published write relay and purplepag es, once, past the broadcast`() {
        val published = listOf("wss://relay.primal.net", "wss://nos.lol/", "wss://relay.damus.io", "ws://127.0.0.1:3355")
        val broadcast = listOf("wss://NOS.lol", "wss://relay.btcforplebs.com")
        assertEquals(
            listOf("wss://relay.primal.net", "wss://relay.damus.io", "wss://purplepag.es"),
            ServerListRelays.extra(published, broadcast),
        )
        // No 10002 known yet: the index relay still gets it.
        assertEquals(listOf("wss://purplepag.es"), ServerListRelays.extra(null, broadcast))
        // Already broadcast there: not twice.
        assertEquals(emptyList<String>(), ServerListRelays.extra(null, listOf("wss://purplepag.es/")))
    }

    /** The 10063 publish uses both: the extra relays, and My Devices as what is never dropped. */
    @Test
    fun `the server list publish is wired to both`() {
        val src = File("src/main/java/com/nostrvault/service/nostr/NostrServiceListPublishing.kt").readText()
        val impl = src.substringAfter("fun NostrService.publishServerListImpl").substringBefore("\n    }\n")
        assertTrue("extra relays", impl.contains("ServerListRelays.extra(_outboxRelays.value[ownerHexPubkey]"))
        assertTrue("publish passes them", impl.contains("publishOwnerEntryList(10063, \"server\", mirrors, extraRelays, publishedFirst = true)"))
        assertTrue("My Devices kept", impl.contains("myDevices = config.fipsPeers"))
    }
}
