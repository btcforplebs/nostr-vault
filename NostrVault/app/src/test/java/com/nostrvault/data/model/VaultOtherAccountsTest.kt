package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

/** Other accounts' Vault lists kept ready so a chip tap only flips the chip (Logen 2026-11-14). */
class VaultOtherAccountsTest {

    private fun ev(id: String, at: Long) = VaultActivity.Event(id, "pk", 1, at, "", emptyList(), emptyList())

    @Test
    fun readsOnlyThePhonesOwnVault() {
        assertEquals(listOf("ws://127.0.0.1:4869", "ws://127.0.0.1:4869/inbox"),
            VaultOtherAccounts.localRelays("ws://127.0.0.1:4869", "ws://127.0.0.1:4869/inbox"))
        assertEquals(listOf("ws://a"), VaultOtherAccounts.localRelays("ws://a", null))
        assertEquals(emptyList<String>(), VaultOtherAccounts.localRelays("", null))
    }

    @Test
    fun everyOtherAccountIsReadAheadOfATap() {
        assertEquals(listOf("bb", "cc"), VaultOtherAccounts.wanted(listOf("aa", "bb", "cc"), "AA"))
        assertEquals(emptyList<String>(), VaultOtherAccounts.wanted(listOf("aa"), "aa"))
    }

    @Test
    fun aTopUpAsksOnlySinceTheNewestHeld() {
        assertEquals("", VaultOtherAccounts.sinceClause(emptyList(), 10_000))
        assertEquals(",\"since\":4940", VaultOtherAccounts.sinceClause(listOf(ev("a", 1_000), ev("b", 5_000)), 10_000))
    }

    @Test
    fun aReadNeverDropsWhatAnEarlierOneBrought() {
        val held = VaultOtherAccounts.fold(emptyMap(), listOf(ev("a", 1), ev("b", 2)))
        // A top-up that brings only the new one keeps the old ones.
        val next = VaultOtherAccounts.fold(held, listOf(ev("c", 3)))
        assertEquals(setOf("a", "b", "c"), next.keys)
        // Nothing new: the same map, so the lines are not rebuilt into a new list.
        assertSame(next, VaultOtherAccounts.fold(next, emptyList()))
    }

    @Test
    fun keepsTheNewestUpToTheCap() {
        val many = (1..10).map { ev("e$it", it.toLong()) }
        val held = VaultOtherAccounts.fold(emptyMap(), many, cap = 4)
        assertEquals(setOf("e7", "e8", "e9", "e10"), held.keys)
    }
}
