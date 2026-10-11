package com.nostrvault.relay

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The block list Android hands its relay: every account's blocks combined, as
 * iOS HavenConfig.allBlockedNpubsAcrossAccounts sends for the same accounts.
 */
class RelayBlacklistTest {

    @Test
    fun `blocks on every account are combined`() {
        val config = HavenConfig(
            ownerNpub = "npub1owner",
            blockedNpubsPerAccount = mapOf(
                "npub1owner" to listOf("npub1alice", "npub1bob"),
                "npub1second" to listOf("npub1bob", "npub1carol"),
            ),
        )
        assertEquals(listOf("npub1alice", "npub1bob", "npub1carol"), config.allBlockedNpubsAcrossAccounts())
    }

    /** iOS folds in the legacy owner-only list too. */
    @Test
    fun `the legacy flat list is included`() {
        val config = HavenConfig(
            blockedNpubs = listOf("npub1legacy", " "),
            blockedNpubsPerAccount = mapOf("npub1owner" to listOf("npub1alice")),
        )
        assertEquals(listOf("npub1alice", "npub1legacy"), config.allBlockedNpubsAcrossAccounts())
    }

    /** Positive control: nobody blocked means an empty list, which unblocks everyone at the relay. */
    @Test
    fun `no blocks is an empty list`() {
        assertEquals(emptyList<String>(), HavenConfig().allBlockedNpubsAcrossAccounts())
        assertEquals("[]", RelayConfiguration.npubListJson(emptyList()))
    }

    @Test
    fun `the relay reads a JSON array of npubs`() {
        assertEquals("[\"npub1a\",\"npub1b\"]", RelayConfiguration.npubListJson(listOf("npub1a", "npub1b")))
    }
}
