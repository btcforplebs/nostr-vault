package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Tron's import risks #3 (2026-11-05): a cut import vanished (START_NOT_STICKY); now it runs again, a bounded number of times. */
class ImportResumeTest {
    private val now = 1_000_000L

    @Test
    fun `a cut import runs again with its options`() {
        val cut = ImportResume.next(null, listHistory = true, alsoFrom = listOf("ws://127.0.0.1:1/x"), otherVault = "ws://127.0.0.1:1/x", nowS = now)
        assertEquals(1, cut.runs)
        assertTrue(ImportResume.shouldResume(cut, now + 60, busy = false))
    }

    @Test
    fun `not while another import runs, not forever, not a day later`() {
        val cut = CutImport(startedAt = now, runs = 1)
        assertFalse(ImportResume.shouldResume(cut, now + 60, busy = true))
        assertFalse(ImportResume.shouldResume(cut.copy(runs = ImportResume.MAX_RUNS), now + 60, busy = false))
        assertFalse(ImportResume.shouldResume(cut, now + ImportResume.MAX_AGE_S + 1, busy = false))
        assertFalse(ImportResume.shouldResume(null, now, busy = false))
    }

    @Test
    fun `each resumed run counts, from the first start`() {
        val first = ImportResume.next(null, false, emptyList(), null, now)
        val second = ImportResume.next(first, false, emptyList(), null, now + 500)
        assertEquals(2, second.runs)
        assertEquals(now, second.startedAt)
    }
}
