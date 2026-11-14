package com.nostrvault.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A refresh reads the store's whole window (Logen 11-14): a note stored late, dated before the newest
 * held, showed a notification but never a Vault row while the store read asked only for what was newer.
 * The socket (the Mac relay, or the store not ready) still only tops up.
 */
class VaultActivityRefreshFiltersTest {
    private val owner = "a".repeat(64)

    @Test
    fun `the store read asks no since, the socket tops up`() {
        val f = VaultActivityViewModel.refreshFilters(owner, since = 1_000L)
        assertEquals(2, f.store.size)
        assertTrue(f.store.none { "since" in it })
        assertTrue(f.socket.all { "\"since\":1000" in it })
    }

    @Test
    fun `nothing held yet - both read the whole window`() {
        val f = VaultActivityViewModel.refreshFilters(owner, since = null)
        assertEquals(f.store, f.socket)
        assertFalse(f.socket.any { "since" in it })
    }
}
