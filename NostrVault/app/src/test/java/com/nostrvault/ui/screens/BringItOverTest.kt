package com.nostrvault.ui.screens

import com.nostrvault.fips.DeviceRole
import com.nostrvault.service.ImportResult
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Setup's "Copy from my other vault" (plan §5a, #1720 twin): how the copy ends and its words. */
class BringItOverTest {
    private fun result(line: String) = ImportResult.parse("IMPORT_RESULT $line")!!

    @Test
    fun onlyTheResultLineEndsTheCopy() {
        assertEquals(BringItOver.Copy.Done, BringItOver.after(result("status=complete reason=ok owner=9 tagged=0 relays=5/5 other_vault=reached")))
        assertEquals("partial but the other vault was read", BringItOver.Copy.Done,
            BringItOver.after(result("status=partial reason=walk_deadline owner=9 tagged=0 relays=4/5 other_vault=reached")))
        assertEquals(BringItOver.Copy.FallBack,
            BringItOver.after(result("status=partial reason=other_vault_not_reached owner=9 tagged=0 relays=4/5 other_vault=not_reached")))
        assertEquals(BringItOver.Copy.FallBack, BringItOver.after(result("status=failed reason=no_seed_relay owner=0 tagged=0 relays=0/5 other_vault=none")))
        assertEquals(BringItOver.Copy.FallBack, BringItOver.after(result("status=cancelled reason=cancelled owner=0 tagged=0 relays=5/5 other_vault=none")))
        assertEquals(BringItOver.Copy.FallBack, BringItOver.after(ImportResult.NO_RESULT))
    }

    @Test
    fun twoMinutesWithoutProgressIsAStall() {
        assertFalse(BringItOver.isStalled(lastProgressAt = 1_000, now = 1_119))
        assertTrue(BringItOver.isStalled(lastProgressAt = 1_000, now = 1_120))
    }

    @Test
    fun readsFromTheMacBackfillEpoch() {
        assertEquals("2020-11-01", BringItOver.START_DATE)
    }

    @Test
    fun wordsMatchIos() {
        assertEquals("Copy from my other vault", BringItOver.COPY)
        assertEquals("Links your devices, then brings your notes from your relays", BringItOver.COPY_DETAIL)
        assertEquals("Your other vault was not reached; getting your notes from your relays instead", BringItOver.FALLBACK_LINE)
        assertEquals("Copying from Logen's Mac…", BringItOver.copyingLine("Logen's Mac"))
        assertEquals("Copying from your other device…", BringItOver.copyingLine("  "))
    }

    @Test
    fun noMeshWordsOnTheseScreens() {
        val words = listOf(
            BringItOver.COPY, BringItOver.COPY_DETAIL, BringItOver.CANCEL, BringItOver.SCAN_TITLE, BringItOver.SCAN_BODY,
            BringItOver.FALLBACK_LINE, BringItOver.showCodeTitle("Mac"), BringItOver.showCodeBody("Mac"),
            BringItOver.linkedLine("Mac"), BringItOver.copyingLine("Mac"),
            com.nostrvault.fips.MeshPairing.roleConfirmText(DeviceRole.MAC, "Logen's Mac", setup = true),
        )
        for (w in words) for (banned in listOf("mesh", "fips", "npub", "address", "role")) {
            assertFalse("\"$banned\" in: $w", w.lowercase().contains(banned))
        }
    }

    @Test
    fun theTourSaysHowItEnded() {
        assertEquals("Couldn't start, try again", tourStoppedTitle(result("status=failed reason=db_init owner=0 tagged=0 relays=0/0 other_vault=none")))
        assertEquals("Couldn't start, try again", tourStoppedTitle(null))
        assertEquals("Import cancelled", tourStoppedTitle(ImportResult.CANCELLED))
        val partial = result("status=partial reason=relay_dropped owner=40 tagged=0 relays=3/4 other_vault=none")
        assertEquals("Some notes may be missing", tourStoppedTitle(partial))
        assertTrue(tourStoppedBody(partial).startsWith("Imported 40 notes, but some may be missing."))
    }
}
