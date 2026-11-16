package com.nostrvault.data.model

import com.nostrvault.relay.HavenConfig
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The Blocked page's Public and Private lists. iOS: BlockedSectionsTests.
 */
class BlockedSectionsTest {
    private val owner = "npub1owner"
    private val second = "npub1second"
    private val alice = "npub1alice"
    private val bob = "npub1bob"
    private val carol = "npub1carol"

    @Test
    fun publicAndPrivateBlocksGoInTheirOwnLists() {
        val lists = BlockedPeople.sections(listOf(alice), listOf(bob))
        assertEquals(listOf(alice), lists.publicBlocks)
        assertEquals(listOf(bob), lists.privateBlocks)
    }

    /** Anyone can already see a public block, so someone in both shows once, as public. */
    @Test
    fun someoneInBothIsShownOnceAsPublic() {
        val lists = BlockedPeople.sections(listOf(alice, bob), listOf(bob, carol))
        assertEquals(listOf(alice, bob), lists.publicBlocks)
        assertEquals(listOf(carol), lists.privateBlocks)
    }

    @Test
    fun repeatsAreDroppedAndOrderKept() {
        val lists = BlockedPeople.sections(listOf(bob, alice, bob), listOf(carol, carol))
        assertEquals(listOf(bob, alice), lists.publicBlocks)
        assertEquals(listOf(carol), lists.privateBlocks)
    }

    @Test
    fun keyDecidesWhenTwoEntriesAreTheSamePerson() {
        val lists = BlockedPeople.sections(listOf("NPUB1ALICE "), listOf(alice))
        assertEquals(listOf("NPUB1ALICE "), lists.publicBlocks)
        assertEquals(emptyList<String>(), lists.privateBlocks)
    }

    @Test
    fun activeAccountsListsComeFromItsOwnPublicAndPrivateBlocks() {
        val cfg = HavenConfig(
            ownerNpub = owner,
            accountNpubs = listOf(second),
            activeAccountNpub = second,
            blockedNpubs = listOf(carol),
            blockedNpubsPerAccount = mapOf(second to listOf(alice)),
            privateBlockedNpubsPerAccount = mapOf(second to listOf(alice, bob), owner to listOf(carol)),
        )
        val lists = BlockedPeople.sections(cfg)
        assertEquals(listOf(alice), lists.publicBlocks)
        assertEquals(listOf(bob), lists.privateBlocks)
    }

    /** The owner with no list of its own shows the legacy blocks as public. */
    @Test
    fun ownerFallsBackToTheLegacyListAsPublic() {
        val cfg = HavenConfig(
            ownerNpub = owner,
            blockedNpubs = listOf(alice),
            privateBlockedNpubsPerAccount = mapOf(owner to listOf(bob)),
        )
        val lists = BlockedPeople.sections(cfg)
        assertEquals(listOf(alice), lists.publicBlocks)
        assertEquals(listOf(bob), lists.privateBlocks)
    }
}
