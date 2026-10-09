package com.nostrvault.service

import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.RelayConfiguration
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * What setup publishes for a key it just generated, and the cleanup of the
 * starter-pack picks the old setup step saved as accounts instead of follows.
 * Mirrors iOS NewAccountSetupTests.
 */
class NewAccountSetupTest {
    // jack and Vitor: correct in the old file and the new one.
    private val jackNpub = "npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m"
    private val vitorNpub = "npub1gcxzte5zlkncx26j68ez60fzkvtkm9e0vrwdcvsjakxf9mu9qewqlfnj5z"

    @Test fun starterPicksWithoutAKeyAreRemoved() {
        val real = "npub1realaccountnotinanystarterpack"
        assertEquals(listOf(real),
            ContactManager.accountsWithoutStarterPackPicks(listOf(jackNpub, real, vitorNpub)) { false })
    }

    @Test fun starterPickWithAKeyIsKept() {
        assertEquals(listOf(jackNpub),
            ContactManager.accountsWithoutStarterPackPicks(listOf(jackNpub, vitorNpub)) { it == jackNpub })
    }

    @Test fun cleanupMatchesEntriesWithStrayWhitespace() {
        assertEquals(emptyList<String>(),
            ContactManager.accountsWithoutStarterPackPicks(listOf(" $jackNpub\n")) { false })
    }

    @Test fun cleanupListIsTheOldShippedFileNotTheCurrentOne() {
        // "fiatjaf" as shipped was really PABLOF7z; the real fiatjaf must not
        // be in the list, or someone who added him as an account loses him.
        assertTrue("npub1l2vyh47mk2p0qlsku7hg0vn29faehy9hy34ygaclpn66ukqp3afqutajft" in ContactManager.starterNpubsSetupAddedAsAccounts)
        assertFalse("npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6" in ContactManager.starterNpubsSetupAddedAsAccounts)
        assertEquals(15, ContactManager.starterNpubsSetupAddedAsAccounts.size)
    }

    @Test fun relayListAdvertisesPublicRelaysOnly() {
        val tags = RelayConfiguration.newAccountRelayListTags(listOf(
            "wss://relay.primal.net",
            "ws://127.0.0.1:4869",
            "wss://localhost:4869",
            "wss://nos.lol",
            "wss://relay.primal.net",
            "https://not-a-relay.example",
            " wss://nostr.mom ",
        ))
        assertEquals(listOf(listOf("r", "wss://relay.primal.net"), listOf("r", "wss://nos.lol"), listOf("r", "wss://nostr.mom")), tags)
    }

    @Test fun newAccountsHostPhotosOnNostrBuildFirst() {
        assertEquals("https://blossom.nostr.build", RelayConfiguration.newAccountBlossomMirrors.first())
    }

    @Test fun everyShippedStarterNpubIsValid() {
        // Gradle runs unit tests from the module dir (NostrVault/app).
        val json = File("src/main/res/raw/starter_packs.json").readText()
        val npubs = Regex("\"npub\"\\s*:\\s*\"([^\"]+)\"").findAll(json).map { it.groupValues[1] }.toList()
        assertTrue(npubs.isNotEmpty())
        for (npub in npubs) assertNotNull(npub, HavenBridge.decodeNpub(npub))
    }
}
