package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** haven-go's IMPORT_RESULT line (import_result.go), the only thing that may call an import done. Twin of iOS ImportResultTests (#1720). */
class ImportResultTest {
    @Test
    fun parsesTheGoLineWithItsLogPrefix() {
        val line = "2026/11/05 02:50:01 📋 IMPORT_RESULT status=complete reason=ok owner=1234 tagged=56 relays=2/3 other_vault=none"
        assertEquals(
            ImportResult(ImportResult.Status.COMPLETE, listOf("ok"), 1234, 56, 2, 3, "none"),
            ImportResult.parse(line),
        )
        assertTrue(ImportResult.parse(line)!!.isComplete)
        assertEquals("Import Complete!", ImportResult.parse(line)!!.summary)
    }

    @Test
    fun partialFailedCancelledAreNeverComplete() {
        val partial = ImportResult.parse("IMPORT_RESULT status=partial reason=walk_deadline,relay_dropped owner=812 tagged=40 relays=3/4 other_vault=none")!!
        assertEquals(listOf("walk_deadline", "relay_dropped"), partial.reasons)
        assertFalse(partial.isComplete)
        assertEquals("Imported 812 notes, but some may be missing. Run the import again to fill the gaps.", partial.summary)

        val offline = ImportResult.parse("IMPORT_RESULT status=failed reason=no_seed_relay owner=0 tagged=0 relays=0/4 other_vault=none")!!
        assertFalse(offline.isComplete)
        assertEquals("Couldn't reach any relay. Check your connection, then try again.", offline.summary)

        val dbInit = ImportResult.parse("IMPORT_RESULT status=failed reason=db_init owner=0 tagged=0 relays=0/0 other_vault=none")!!
        assertEquals("Couldn't start, try again", dbInit.summary)

        val cancelled = ImportResult.parse("IMPORT_RESULT status=cancelled reason=cancelled owner=10 tagged=0 relays=4/4 other_vault=none")!!
        assertEquals("Import cancelled", cancelled.summary)
        for (r in listOf(partial, offline, dbInit, cancelled, ImportResult.NO_RESULT, ImportResult.CANCELLED, ImportResult.APP_FAILED)) {
            assertFalse(r.isComplete)
            assertNotEquals(ImportResult.COMPLETE_LINE, r.summary)
        }
        assertEquals("no result line is a start that didn't happen", ImportResult.COULD_NOT_START, ImportResult.NO_RESULT.summary)
    }

    @Test
    fun leftoverCycleSaysBusy() {
        val draining = ImportResult.parse("IMPORT_RESULT status=failed reason=still_draining owner=0 tagged=0 relays=0/0 other_vault=none")!!
        assertEquals("The vault was still shutting down, so the import didn't start. Your vault is starting again; try Import notes in a moment.", draining.summary)
    }

    @Test
    fun otherVaultNotReached() {
        val r = ImportResult.parse("IMPORT_RESULT status=partial reason=other_vault_not_reached owner=300 tagged=2 relays=4/5 other_vault=not_reached")!!
        assertTrue(r.otherVaultNotReached)
        assertEquals(ImportResult.OTHER_VAULT_NOT_REACHED_LINE, r.summary)
        assertFalse(ImportResult.parse("IMPORT_RESULT status=complete reason=ok owner=1 tagged=0 relays=5/5 other_vault=reached")!!.otherVaultNotReached)
    }

    @Test
    fun unknownKeysIgnoredAndJunkRefused() {
        assertEquals(3, ImportResult.parse("IMPORT_RESULT status=complete reason=ok future=7 owner=3 tagged=1 relays=1/1 other_vault=none")?.owner)
        assertNull(ImportResult.parse("IMPORT_RESULT status=great reason=ok"))
        assertNull(ImportResult.parse("✅ Import completed in C-Shared mode"))
        assertNull(ImportResult.parse(""))
        assertNull(ImportResult.parse(null))
    }
}
