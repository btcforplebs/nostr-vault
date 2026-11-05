package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VaultAccountChipsTest {
    private val me = "a".repeat(64)
    private val bob = "b".repeat(64)
    private val cat = "c".repeat(64)

    private fun line(id: String, at: Long, kind: VaultActivity.Kind = VaultActivity.Kind.REPLY) =
        VaultActivity(id = id, kind = kind, actors = listOf("x"), createdAt = at, openId = id, preview = "")

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
            mapOf(
                bob to listOf(line("follow-2026-10-31", 100, VaultActivity.Kind.FOLLOW)),
                me to listOf(line("follow-2026-10-31", 100, VaultActivity.Kind.FOLLOW)),
            ),
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

    // The pages' row (Logen 11-02): the Vault list's chips, filter only (VaultPageAccountsTest).

    @Test
    fun everyPageButMediaAndTheVaultListShowsTheChipRow() {
        for (mode in listOf(VaultMode.NOTES, VaultMode.ARTICLES, VaultMode.HIGHLIGHTS, VaultMode.LIKES, VaultMode.ZAPS, VaultMode.FOLLOWERS)) {
            assertTrue(mode.name, VaultAccountChips.pageShowsChipRow(mode))
        }
        // The Vault list has its own row; Media has none.
        assertFalse(VaultAccountChips.pageShowsChipRow(VaultMode.ACTIVITY))
        assertFalse(VaultAccountChips.pageShowsChipRow(VaultMode.MEDIA))
        // Bookmarks is the active account's list only.
        assertFalse(VaultAccountChips.pageShowsChipRow(VaultMode.BOOKMARKS))
    }

    /** Live Vault §1 (iOS #1772): a reply that tagged two of your accounts was two rows, unread twice. */
    @Test fun oneEventTaggingSeveralAccountsIsOneRow() {
        val merged = VaultAccountChips.merge(
            mapOf(bob to listOf(line("e1", 300)), me to listOf(line("e1", 300), line("m2", 100)), cat to listOf(line("e1", 300))),
            listOf(me, bob, cat), 10,
        )
        assertEquals(listOf("e1", "m2"), merged.map { it.line.id })
        // The shared line's accounts in switcher order; its key stays unique.
        assertEquals(listOf(me, bob, cat), merged.first().accounts)
        assertEquals(me, merged.first().account)
        assertEquals(2, merged.map { it.key }.toSet().size)
    }

    @Test fun foldedLinesStayPerAccount() {
        for (kind in listOf(VaultActivity.Kind.REACTION, VaultActivity.Kind.REPOST, VaultActivity.Kind.FOLLOW)) {
            val merged = VaultAccountChips.merge(mapOf(me to listOf(line("x-1", 100, kind)), bob to listOf(line("x-1", 100, kind))), listOf(me, bob), 10)
            assertEquals(kind.name, 2, merged.size)
        }
        // A zap with its own words is one event; the folded "zap-" line is per account.
        assertEquals(1, VaultAccountChips.merge(mapOf(me to listOf(line("z1", 1, VaultActivity.Kind.ZAP)), bob to listOf(line("z1", 1, VaultActivity.Kind.ZAP))), listOf(me, bob), 10).size)
        assertEquals(2, VaultAccountChips.merge(mapOf(me to listOf(line("zap-p", 1, VaultActivity.Kind.ZAP)), bob to listOf(line("zap-p", 1, VaultActivity.Kind.ZAP))), listOf(me, bob), 10).size)
    }
}
