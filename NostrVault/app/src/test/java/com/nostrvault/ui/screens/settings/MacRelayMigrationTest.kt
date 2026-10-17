package com.nostrvault.ui.screens.settings

import com.nostrvault.relay.HavenConfig
import org.junit.Assert.assertEquals
import org.junit.Test

class MacRelayMigrationTest {
    private val old = HavenConfig(
        macRelayURL = "https://old.example.com",
        feedRelays = listOf("wss://old.example.com", "wss://other.example.com"),
        importSeedRelays = listOf("wss://other.example.com", "wss://old.example.com"),
        blastrRelays = listOf("wss://old.example.com"),
        blossomMirrors = listOf("https://old.example.com", "https://keep.example.com"),
    )

    @Test fun derivedEntriesFollowTheNewAddress() {
        val c = withMacRelayURL(old, "https://new.example.com")
        assertEquals(listOf("wss://new.example.com", "wss://other.example.com"), c.feedRelays)
        assertEquals(listOf("wss://other.example.com", "wss://new.example.com"), c.importSeedRelays)
        assertEquals(listOf("wss://new.example.com"), c.blastrRelays)
        assertEquals(listOf("https://new.example.com", "https://keep.example.com"), c.blossomMirrors)
    }

    @Test fun clearingTheAddressRemovesDerivedEntriesOnly() {
        val c = withMacRelayURL(old, "")
        assertEquals(listOf("wss://other.example.com"), c.feedRelays)
        assertEquals(emptyList<String>(), c.blastrRelays)
        assertEquals(listOf("https://keep.example.com"), c.blossomMirrors)
    }

    @Test fun anUnchangedAddressTouchesNothing() {
        assertEquals(old, withMacRelayURL(old, "https://old.example.com"))
    }

    @Test fun firstTimeSetLeavesTheListsAlone() {
        val blank = old.copy(macRelayURL = "")
        val c = withMacRelayURL(blank, "https://new.example.com")
        assertEquals(blank.feedRelays, c.feedRelays)
        assertEquals(blank.blossomMirrors, c.blossomMirrors)
    }

    @Test fun theOldDMInboxIsDropped() {
        val withInbox = old.copy(dmRelays = listOf("wss://old.example.com/inbox", "wss://dm.example.com"))
        val c = withMacRelayURL(withInbox, "https://new.example.com")
        assertEquals(listOf("wss://dm.example.com"), c.dmRelays)
    }
}
