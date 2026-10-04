package com.nostrvault.relay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors the iOS DMInboxRelaysTests (nostr-vault #210). */
class DMInboxTest {

    @Test fun havenInboxComesFirstAndDuplicatesCollapse() {
        assertEquals(
            listOf("wss://vault.example.com/inbox", "wss://relay.primal.net"),
            DMInbox.merged("wss://vault.example.com/inbox",
                listOf("wss://relay.primal.net", "wss://vault.example.com/inbox/", "wss://Relay.Primal.net/")),
        )
    }

    @Test fun macRelayBecomesTheHavenInbox() {
        val config = HavenConfig(macRelayURL = "https://logen.btcforplebs.com/")
        assertEquals("wss://logen.btcforplebs.com/inbox", config.ownHavenDMInboxURL)
        assertEquals("wss://logen.btcforplebs.com/inbox", config.dmInboxRelays.first())
    }

    @Test fun unreachableMacAddressesAreNeverPublished() {
        for (typed in listOf("", "ws://logen.btcforplebs.com", "http://x.example.com", "192.168.1.20:3355", "mac.local", "100.68.246.56:8798")) {
            assertEquals(typed, "", HavenConfig(macRelayURL = typed).ownHavenDMInboxURL)
        }
    }

    @Test fun privateAddressesAreRecognised() {
        for (h in listOf("192.168.1.20:3355", "10.0.0.5", "172.16.4.1:80", "127.0.0.1", "169.254.1.1", "100.68.246.56:8798",
            "localhost:3355", "mac.local", "mac.local.", "studio-mac", "[::1]:3355", "[fd12::1]", "[fe80::1]:80",
            "[::ffff:192.168.1.20]:3355", "nas.lan", "box.home.arpa", "svc.internal", "mac.tail1234.ts.net")) {
            assertTrue(h, DMInbox.isPrivateNetworkHost(h))
        }
        for (h in listOf("logen.btcforplebs.com", "relay.example.com:443", "172.217.4.14", "172.32.0.1", "100.128.0.1",
            "8.8.8.8", "[2606:4700::1111]", "[::ffff:8.8.8.8]", "lan.example.com")) {
            assertFalse(h, DMInbox.isPrivateNetworkHost(h))
        }
    }

    @Test fun syncActions() {
        val s = DMInbox::syncAction
        assertEquals(DMInbox.SyncAction.PUBLISH, s(listOf("wss://a"), null, null, null))
        // A synced device that finds nothing most likely could not reach the relays.
        assertEquals(DMInbox.SyncAction.NONE, s(listOf("wss://a"), 100, null, null))
        // Defaults never overwrite a published list.
        assertEquals(DMInbox.SyncAction.ADOPT, s(listOf("wss://defaults"), null, listOf("wss://chosen"), 100))
        assertEquals(DMInbox.SyncAction.ADOPT, s(listOf("wss://old"), 100, listOf("wss://new"), 200))
        assertEquals(DMInbox.SyncAction.PUBLISH, s(listOf("wss://edited"), 300, listOf("wss://old"), 200))
        assertEquals(DMInbox.SyncAction.NONE, s(listOf("wss://b", "wss://a/"), 200, listOf("wss://a", "wss://B"), 200))
        assertEquals(DMInbox.SyncAction.PUBLISH, s(listOf("wss://vault/inbox", "wss://a"), 200, listOf("wss://a"), 200))
    }
}
