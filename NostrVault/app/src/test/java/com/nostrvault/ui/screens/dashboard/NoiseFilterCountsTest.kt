package com.nostrvault.ui.screens.dashboard

import com.nostrvault.relay.HavenConfig
import org.junit.Assert.assertEquals
import org.junit.Test

/** The Feed Dashboard's Blocked / Blacklisted figures. */
class NoiseFilterCountsTest {

    private val base = HavenConfig(ownerNpub = "npub1owner", accountNpubs = listOf("npub1alt"))

    @Test
    fun `nothing blocked counts zero`() {
        assertEquals(NoiseFilterCounts(0, 0), NoiseFilterCounts.of(base))
    }

    @Test
    fun `blocked is the active account's list, blacklisted spans every account`() {
        val config = base.copy(
            activeAccountNpub = "npub1alt",
            blockedNpubsPerAccount = mapOf(
                "npub1owner" to listOf("npub1a", "npub1b"),
                "npub1alt" to listOf("npub1b", "npub1c", "npub1d"),
            ),
        )
        assertEquals(NoiseFilterCounts(blocked = 3, blacklisted = 4), NoiseFilterCounts.of(config))
    }

    @Test
    fun `legacy flat list counts only while the owner has no per-account list`() {
        val legacyOnly = base.copy(blockedNpubs = listOf("npub1a", "npub1b"))
        assertEquals(NoiseFilterCounts(2, 2), NoiseFilterCounts.of(legacyOnly))

        // Unblocking updates the per-account list; a stale legacy entry must not linger.
        val migrated = legacyOnly.copy(blockedNpubsPerAccount = mapOf("npub1owner" to listOf("npub1a")))
        assertEquals(NoiseFilterCounts(1, 1), NoiseFilterCounts.of(migrated))
    }

    @Test
    fun `a duplicate entry is one person`() {
        val config = base.copy(blockedNpubsPerAccount = mapOf("npub1owner" to listOf("npub1a", "npub1a")))
        assertEquals(NoiseFilterCounts(1, 1), NoiseFilterCounts.of(config))
    }
}
