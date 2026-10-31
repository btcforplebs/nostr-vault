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

    @Test fun nothingConfiguredIsEmpty() {
        assertEquals(emptyList<String>(), HavenConfig().blossomDeleteTargets(emptyList(), null, includeHomeVault = true))
    }
}
