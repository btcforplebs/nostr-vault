package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The pages' account chips filter loaded data (Logen 11-02). */
class VaultPageAccountsTest {
    private val accounts = listOf("aa", "bb", "cc")

    @Test
    fun nothingPickedIsTheActiveAccountsOwnPage() {
        assertEquals(listOf("bb"), VaultPageAccounts.owners(null, accounts, "BB"))
    }

    @Test
    fun allShowsEveryAccountActiveFirst() {
        assertEquals(listOf("bb", "aa", "cc"), VaultPageAccounts.owners(VaultAccountChip.All, accounts, "bb"))
    }

    @Test
    fun oneChipShowsThatAccountAlone() {
        assertEquals(listOf("cc"), VaultPageAccounts.owners(VaultAccountChip.Account("cc"), accounts, "aa"))
    }

    @Test
    fun aChipThatIsGoneFallsBackToTheActiveAccount() {
        assertEquals(listOf("aa"), VaultPageAccounts.owners(VaultAccountChip.Account("zz"), accounts, "aa"))
        // Down to one account: no chips, so "All" is gone too.
        assertEquals(listOf("aa"), VaultPageAccounts.owners(VaultAccountChip.All, listOf("aa"), "aa"))
    }

    @Test
    fun aRowIsForItsAuthorThenTheFirstShownAccountItTags() {
        val tags = listOf(listOf("e", "x"), listOf("p", "CC"), listOf("p", "bb"))
        assertEquals("aa", VaultPageAccounts.rowAccount("aa", tags, listOf("aa", "bb", "cc")))
        assertEquals("bb", VaultPageAccounts.rowAccount("zz", tags, listOf("aa", "bb", "cc")))
        assertEquals("cc", VaultPageAccounts.rowAccount("zz", tags, listOf("cc", "bb")))
        // A whitelisted author tagging none of the shown accounts.
        assertNull(VaultPageAccounts.rowAccount("zz", tags, listOf("aa")))
    }

    @Test
    fun subscriptionsAskForEveryAccount() {
        assertEquals(listOf("bb", "aa", "cc", "ww"), VaultPageAccounts.authors(accounts, "BB", listOf("ww")).toList())
        assertEquals(listOf("bb", "aa", "cc"), VaultPageAccounts.tagged(accounts, "bb"))
        // Before the key is known: just the device's accounts.
        assertEquals(listOf("aa", "bb", "cc"), VaultPageAccounts.tagged(accounts, ""))
    }

    @Test
    fun dotsCountOnlyTheActiveAccountsOwnEvents() {
        val wl = setOf("ww")
        assertTrue(VaultPageAccounts.isActiveAccounts("aa", emptyList(), "aa", wl))
        assertTrue(VaultPageAccounts.isActiveAccounts("ww", emptyList(), "aa", wl))
        assertTrue(VaultPageAccounts.isActiveAccounts("zz", listOf(listOf("p", "aa")), "aa", wl))
        assertFalse(VaultPageAccounts.isActiveAccounts("bb", emptyList(), "aa", wl))
        assertFalse(VaultPageAccounts.isActiveAccounts("zz", listOf(listOf("p", "bb")), "aa", wl))
    }

    @Test
    fun followersMergeOncePerFollowerAndCountsAdd() {
        fun e(pk: String, at: Long, following: Boolean = true) =
            FollowerSnapshot.Entry(pubkey = pk, following = following, followedAt = at)
        val a = FollowerSnapshot(FollowerSnapshot.Counts(trusted = 2, others = 1), listOf(e("x", 10), e("y", 5, following = false)))
        val b = FollowerSnapshot(FollowerSnapshot.Counts(trusted = 1, spam = 3), listOf(e("x", 20), e("y", 1)))
        val merged = VaultPageAccounts.mergeFollowers(listOf(a, b))!!
        assertEquals(listOf("x", "y"), merged.followers!!.map { it.pubkey })
        assertEquals(20L, merged.followers!!.first { it.pubkey == "x" }.followedAt)
        // A current follow wins over an ended one, though older.
        assertTrue(merged.followers!!.first { it.pubkey == "y" }.following)
        assertEquals(FollowerSnapshot.Counts(trusted = 3, others = 1, spam = 3), merged.counts)
        assertEquals(a, VaultPageAccounts.mergeFollowers(listOf(a)))
        assertNull(VaultPageAccounts.mergeFollowers(emptyList()))
    }

    // ── Report / Block on page rows (iOS #1562) ──

    @Test
    fun anyAccountOnThisDeviceIsOwn() {
        assertTrue(VaultPageAccounts.isOwnAccount("CC", accounts, "bb"))
        assertTrue(VaultPageAccounts.isOwnAccount("bb", emptyList(), "BB"))
        assertFalse(VaultPageAccounts.isOwnAccount("dd", accounts, "bb"))
    }

    @Test
    fun strangersRowForTheActiveAccountKeepsTheMenu() {
        assertTrue(VaultPageAccounts.showsRowMenu("dd", null, accounts, "bb"))
    }

    @Test
    fun rowListedForAnotherAccountHasNoMenu() {
        assertFalse(VaultPageAccounts.showsRowMenu("dd", "aa", accounts, "bb"))
    }

    @Test
    fun noteByAnotherAccountOnThisDeviceHasNoMenu() {
        assertFalse(VaultPageAccounts.showsRowMenu("aa", null, accounts, "bb"))
        assertFalse(VaultPageAccounts.showsRowMenu("bb", null, accounts, "bb"))
    }
}
