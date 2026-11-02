package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VaultAccountChipsTest {
    private val me = "a".repeat(64)
    private val bob = "b".repeat(64)
    private val cat = "c".repeat(64)

    private fun line(id: String, at: Long) =
        VaultActivity(id = id, kind = VaultActivity.Kind.REPLY, actors = listOf("x"), createdAt = at, openId = id, preview = "")

    @Test fun oneAccountShowsNoChips() {
        assertEquals(emptyList<VaultAccountChip>(), VaultAccountChips.chips(listOf(me), me))
        assertEquals(emptyList<VaultAccountChip>(), VaultAccountChips.chips(listOf(me, me.uppercase()), me))
        assertEquals(VaultAccountChip.Account(me), VaultAccountChips.resolve(VaultAccountChip.All, listOf(me), me))
    }

    @Test fun chipsLeadWithAllThenActiveAccount() {
        assertEquals(
            listOf(VaultAccountChip.All, VaultAccountChip.Account(bob), VaultAccountChip.Account(me), VaultAccountChip.Account(cat)),
            VaultAccountChips.chips(listOf(me, bob, cat), bob),
        )
    }

    @Test fun defaultIsActiveAccount() {
        assertEquals(VaultAccountChip.Account(me), VaultAccountChips.resolve(null, listOf(me, bob), me))
        assertTrue(VaultAccountChips.isDefault(VaultAccountChip.Account(me), me))
        assertFalse(VaultAccountChips.isDefault(VaultAccountChip.All, me))
        assertFalse(VaultAccountChips.isDefault(VaultAccountChip.Account(bob), me))
    }

    @Test fun removedAccountFallsBackToActive() {
        assertEquals(VaultAccountChip.Account(me), VaultAccountChips.resolve(VaultAccountChip.Account(cat), listOf(me, bob), me))
        assertEquals(VaultAccountChip.Account(bob), VaultAccountChips.resolve(VaultAccountChip.Account(bob), listOf(me, bob), me))
    }

    @Test fun chipAccounts() {
        assertEquals(listOf(me, bob), VaultAccountChips.accounts(VaultAccountChip.All, listOf(me, bob, me)))
        assertEquals(listOf(bob), VaultAccountChips.accounts(VaultAccountChip.Account(bob.uppercase()), listOf(me, bob)))
    }

    @Test fun mergeInterleavesNewestFirstAndKeepsAccount() {
        val merged = VaultAccountChips.merge(
            mapOf(me to listOf(line("m1", 300), line("m2", 100)), bob to listOf(line("b1", 200))),
            listOf(me, bob), 10,
        )
        assertEquals(listOf("m1", "b1", "m2"), merged.map { it.line.id })
        assertEquals(listOf(me, bob, me), merged.map { it.account })
    }

    @Test fun sameLineIdInTwoAccountsStaysTwoRows() {
        val merged = VaultAccountChips.merge(
            mapOf(bob to listOf(line("follow-2026-10-31", 100)), me to listOf(line("follow-2026-10-31", 100))),
            listOf(me, bob), 10,
        )
        assertEquals(2, merged.map { it.key }.toSet().size)
        // A tie goes to the account first in order, every time.
        assertEquals(listOf(me, bob), merged.map { it.account })
    }

    @Test fun tieGoesToAccountOrderBeforeId() {
        val merged = VaultAccountChips.merge(mapOf(bob to listOf(line("a", 100)), me to listOf(line("z", 100))), listOf(me, bob), 10)
        assertEquals(listOf(me, bob), merged.map { it.account })
    }

    @Test fun mergeCapsAtLimit() {
        val merged = VaultAccountChips.merge(
            mapOf(me to listOf(line("1", 5), line("2", 4)), bob to listOf(line("3", 3))),
            listOf(me, bob), 2,
        )
        assertEquals(listOf("1", "2"), merged.map { it.line.id })
    }

    @Test fun switchTargetOnlyForAnotherHeldAccount() {
        val npubs = mapOf(me to "npub1me", bob to "npub1bob")
        // Another account's line: switch to it, whatever the case of the hex.
        assertEquals("npub1bob", VaultAccountChips.switchTarget(bob.uppercase(), me, npubs))
        // The active account's own line, or a list with one account: no switch.
        assertEquals(null, VaultAccountChips.switchTarget(me, me.uppercase(), npubs))
        assertEquals(null, VaultAccountChips.switchTarget(null, me, npubs))
        // An account the device no longer holds: nothing to switch to.
        assertEquals(null, VaultAccountChips.switchTarget(cat, me, npubs))
    }

    // The row on the other pages (Logen 11-02, option B; iOS VaultAccountChipsTests).

    @Test
    fun otherPagesGetEveryAccountButNoAll() {
        val chips = VaultAccountChips.switchChips(listOf("bb", "aa", "cc"), "AA")
        assertEquals(listOf(VaultAccountChip.Account("aa"), VaultAccountChip.Account("bb"), VaultAccountChip.Account("cc")), chips)
        assertFalse(VaultAccountChip.All in chips)
    }

    @Test
    fun oneAccountShowsNoRowOnAnyPage() {
        assertEquals(emptyList<VaultAccountChip>(), VaultAccountChips.switchChips(listOf("aa"), "aa"))
        assertEquals(emptyList<VaultAccountChip>(), VaultAccountChips.switchChips(emptyList(), "aa"))
    }

    @Test
    fun everyPageButMediaAndTheVaultListShowsTheSwitchRow() {
        for (mode in listOf(VaultMode.NOTES, VaultMode.ARTICLES, VaultMode.HIGHLIGHTS, VaultMode.LIKES, VaultMode.ZAPS, VaultMode.FOLLOWERS)) {
            assertTrue(mode.name, VaultAccountChips.pageShowsSwitchRow(mode))
        }
        // The Vault list has its own row (with All); Media has none.
        assertFalse(VaultAccountChips.pageShowsSwitchRow(VaultMode.ACTIVITY))
        assertFalse(VaultAccountChips.pageShowsSwitchRow(VaultMode.MEDIA))
    }

    // No flash on a pick (Logen 11-02; iOS testAPickWaitsOnlyForAnotherAccountNotReadYet).

    @Test
    fun aPickWaitsOnlyForAnotherAccountNotReadYet() {
        val accounts = listOf("aa", "bb", "cc")
        // The active account's own list is always there.
        assertFalse(VaultAccountChips.needsRead(VaultAccountChip.Account("aa"), accounts, "AA", emptySet()))
        // Another account not read yet: wait, keep the list on screen.
        assertTrue(VaultAccountChips.needsRead(VaultAccountChip.Account("bb"), accounts, "aa", emptySet()))
        assertFalse(VaultAccountChips.needsRead(VaultAccountChip.Account("bb"), accounts, "aa", setOf("bb")))
        // All waits until every other account is read.
        assertTrue(VaultAccountChips.needsRead(VaultAccountChip.All, accounts, "aa", setOf("bb")))
        assertFalse(VaultAccountChips.needsRead(VaultAccountChip.All, accounts, "aa", setOf("bb", "cc")))
    }
}
