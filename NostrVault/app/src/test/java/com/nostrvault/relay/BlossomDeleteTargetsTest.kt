package com.nostrvault.relay

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * One delete target list (Tim, 2026-10-31): configured mirrors + the owner's
 * kind 10063 servers + the photo's own host, each once. "Delete from mirrors"
 * leaves the home vault out; "Delete everywhere" keeps it.
 */
class BlossomDeleteTargetsTest {

    private val config = HavenConfig(
        macRelayURL = "wss://mac.example.com",
        blossomMirrors = listOf("https://blossom.primal.net", "https://cdn.satellite.earth/"),
    )
    private val published = listOf("https://Blossom.Primal.net/", "https://nostr.download", "https://mac.example.com")
    private val photo = "https://image.nostr.build/${"a".repeat(64)}.jpg"

    @Test fun mirrorsOnlyTakesEveryPublicServerOnceAndLeavesTheHomeVaultOut() {
        assertEquals(
            listOf(
                "https://blossom.primal.net",
                "https://cdn.satellite.earth/",
                "https://nostr.download",
                "https://image.nostr.build",
            ),
            config.blossomDeleteTargets(published, photo, includeHomeVault = false),
        )
    }

    @Test fun everywhereAsksTheHomeVaultFirst() {
        val targets = config.blossomDeleteTargets(published, photo, includeHomeVault = true)
        assertEquals("https://mac.example.com", targets.first())
        assertEquals(5, targets.size)
    }

    @Test fun aPhotoOnTheHomeVaultIsNotAMirror() {
        val onMac = "https://mac.example.com/${"a".repeat(64)}"
        assertEquals(
            listOf("https://blossom.primal.net", "https://cdn.satellite.earth/"),
            config.blossomDeleteTargets(emptyList(), onMac, includeHomeVault = false),
        )
    }

    @Test fun meshNamesLoopbackPhotosAndNonHttpEntriesAreNeverTargets() {
        val targets = HavenConfig(blossomMirrors = listOf("https://blossom.primal.net"))
            .blossomDeleteTargets(
                listOf("http://npub1abc.fips:3355", "fipsmesh://npub1abc/", "not a url"),
                photoUrl = "http://127.0.0.1:3355/${"a".repeat(64)}",
                includeHomeVault = true,
            )
        assertEquals(listOf("https://blossom.primal.net"), targets)
    }

    /**
     * Tron ship check 2026-10-31: the 10063 keeps other devices' entries, so
     * the home vault can be listed under a name this device does not use. A
     * mirror delete to it removed what may be the last copy.
     */
    @Test fun mirrorsNeverTargetsTheOwnersOwnVaultsUnderAnyName() {
        val sameMacOtherSpelling = "https://MAC.example.com:443/"
        val ownVaults = listOf(
            "http://192.168.1.20:3355", "https://studio.local", "https://mac.tail1234.ts.net",
            "http://other-mac.example.com", "http://127.0.0.1:3355", "https://10.0.0.7",
            "http://npub1abc.fips:3355", "fipsmesh://npub1abc/",
        )
        val targets = config.blossomDeleteTargets(
            listOf("https://mac.example.com/", sameMacOtherSpelling) + ownVaults + "https://nostr.download",
            photoUrl = "http://192.168.1.20:3355/${"a".repeat(64)}.jpg",
            includeHomeVault = false,
        )
        assertEquals(listOf("https://blossom.primal.net", "https://cdn.satellite.earth/", "https://nostr.download"), targets)
    }

    @Test fun everywhereStillReachesHomeNetworkServers() {
        val targets = config.blossomDeleteTargets(listOf("http://192.168.1.20:3355", "https://studio.local"), null, includeHomeVault = true)
        assertEquals(
            listOf("https://mac.example.com", "https://blossom.primal.net", "https://cdn.satellite.earth/", "http://192.168.1.20:3355", "https://studio.local"),
            targets,
        )
    }

    @Test fun nothingConfiguredIsEmpty() {
        assertEquals(emptyList<String>(), HavenConfig().blossomDeleteTargets(emptyList(), null, includeHomeVault = true))
    }
}
