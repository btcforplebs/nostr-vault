package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class VaultReturnRulesTest {

    // ── List swap ──

    @Test
    fun `a build with no read on shows at once`() {
        assertTrue(VaultListSwap.publishes(force = false, refreshing = false, heldForMs = null))
    }

    @Test
    fun `a build during a read is held - followers never show alone`() {
        assertFalse(VaultListSwap.publishes(force = false, refreshing = true, heldForMs = null))
        assertFalse(VaultListSwap.publishes(force = false, refreshing = true, heldForMs = 0))
        assertFalse(VaultListSwap.publishes(force = false, refreshing = true, heldForMs = VaultListSwap.CAP_MS - 1))
    }

    @Test
    fun `a read that never ends shows the list after the cap`() {
        assertTrue(VaultListSwap.publishes(force = false, refreshing = true, heldForMs = VaultListSwap.CAP_MS))
    }

    @Test
    fun `the saved screen shows at once even while reading`() {
        assertTrue(VaultListSwap.publishes(force = true, refreshing = true, heldForMs = null))
    }

    // ── Saved screen ──

    @Test
    fun `the saved screen keeps the newest, newest first`() {
        val kept = VaultSnapshotRules.newest(listOf(5L, 9L, 1L, 7L), keep = 2) { it }
        assertEquals(listOf(9L, 7L), kept)
    }

    @Test
    fun `the saved screen file is the account hex only`() {
        val hex = "A".repeat(64)
        assertEquals("vault-activity-${"a".repeat(64)}.json", VaultSnapshotRules.fileName("vault-activity", hex))
        assertNull(VaultSnapshotRules.fileName("vault-activity", "../" + "a".repeat(61)))
        assertNull(VaultSnapshotRules.fileName("vault-activity", "a".repeat(63)))
        assertNull(VaultSnapshotRules.fileName("vault-activity", ""))
    }

    // ── Dot per account ──

    @Test
    fun `each account keeps its own dot across a switch`() {
        val accounts = VaultNewsAccounts<String>()
        // A had Likes lit; switching to B (never opened) shows nothing.
        assertEquals(emptySet<String>(), accounts.switchAccount("aa", "bb", setOf("LIKES")))
        // B got Zaps; back on A, A's Likes come back, not B's Zaps.
        assertEquals(setOf("LIKES"), accounts.switchAccount("bb", "AA", setOf("ZAPS")))
        assertEquals(setOf("ZAPS"), accounts.switchAccount("aa", "bb", emptySet()))
    }

    @Test
    fun `switching to the same account keeps the dot`() {
        val accounts = VaultNewsAccounts<String>()
        assertEquals(setOf("LIKES"), accounts.switchAccount("aa", "aa", setOf("LIKES")))
    }

    @Test
    fun `only something after the last visit is news`() {
        assertFalse(VaultNewsAccounts.isNews(listOf(100L, 200L), lastVisit = 200L))
        assertTrue(VaultNewsAccounts.isNews(listOf(100L, 201L), lastVisit = 200L))
        assertTrue(VaultNewsAccounts.isNews(listOf(5L), lastVisit = null))
        assertFalse(VaultNewsAccounts.isNews(emptyList(), lastVisit = null))
    }
}
