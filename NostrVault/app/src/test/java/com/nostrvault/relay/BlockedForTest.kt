package com.nostrvault.relay

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Only the owner falls back to the legacy flat block list. A second account
 * with no list of its own used to show the owner's blocks as its own.
 */
class BlockedForTest {
    private val owner = "npub1owner"
    private val second = "npub1second"
    private val alice = "npub1alice"
    private val bob = "npub1bob"

    private val legacyOnly = HavenConfig(ownerNpub = owner, accountNpubs = listOf(second), blockedNpubs = listOf(alice))

    @Test
    fun ownerWithNoListOfItsOwnSeesTheLegacyList() {
        assertEquals(listOf(alice), legacyOnly.blockedFor(owner))
    }

    @Test
    fun secondAccountWithNoListOfItsOwnSeesNobodyBlocked() {
        assertEquals(emptyList<String>(), legacyOnly.blockedFor(second))
        assertEquals(emptyList<String>(), legacyOnly.copy(activeAccountNpub = second).blockedForActiveAccount())
    }

    @Test
    fun anAccountsOwnListWins() {
        val cfg = legacyOnly.copy(blockedNpubsPerAccount = mapOf(owner to listOf(bob), second to listOf(bob)))
        assertEquals(listOf(bob), cfg.blockedFor(owner))
        assertEquals(listOf(bob), cfg.blockedFor(second))
    }

    /** The relay's blacklist is global and still includes the owner's legacy blocks. */
    @Test
    fun relayBlacklistStillHasTheLegacyList() {
        assertEquals(listOf(alice), legacyOnly.allBlockedNpubsAcrossAccounts())
    }
}
