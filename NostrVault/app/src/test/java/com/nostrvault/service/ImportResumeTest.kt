package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Tron's import risks #3 (2026-11-05): a cut import vanished (START_NOT_STICKY); now it runs again, a bounded number of times. */
class ImportResumeTest {
    private val now = 1_000_000L
    private val alice = "aa".repeat(32)
    private val bob = "bb".repeat(32)

    @Test
    fun `a cut import runs again with its options`() {
        val cut = ImportResume.next(null, listHistory = true, alsoFrom = listOf("ws://127.0.0.1:1/x"), otherVault = "ws://127.0.0.1:1/x", nowS = now, account = alice)
        assertEquals(1, cut.runs)
        assertTrue(ImportResume.shouldResume(cut, now + 60, busy = false, activeAccount = alice))
    }

    @Test
    fun `not while another import runs, not forever, not a day later`() {
        val cut = CutImport(startedAt = now, runs = 1, account = alice)
        assertFalse(ImportResume.shouldResume(cut, now + 60, busy = true, activeAccount = alice))
        assertFalse(ImportResume.shouldResume(cut.copy(runs = ImportResume.MAX_RUNS), now + 60, busy = false, activeAccount = alice))
        assertFalse(ImportResume.shouldResume(cut, now + ImportResume.MAX_AGE_S + 1, busy = false, activeAccount = alice))
        assertFalse(ImportResume.shouldResume(null, now, busy = false, activeAccount = alice))
    }

    @Test
    fun `each resumed run counts, from the first start`() {
        val first = ImportResume.next(null, false, emptyList(), null, now, alice)
        val second = ImportResume.next(first, false, emptyList(), null, now + 500, alice)
        assertEquals(2, second.runs)
        assertEquals(now, second.startedAt)
    }

    /** Tron on #1758: a cut import resumed after an account switch moved in the wrong account's lists. */
    @Test
    fun `a cut import from another account is dropped, not resumed`() {
        val cut = ImportResume.next(null, true, emptyList(), null, now, alice)
        assertEquals(alice, cut.account)
        assertFalse(ImportResume.shouldResume(cut, now + 60, busy = false, activeAccount = bob))
        // And a new import by another account starts its own count.
        assertEquals(1, ImportResume.next(cut, true, emptyList(), null, now + 60, bob).runs)
    }
}
