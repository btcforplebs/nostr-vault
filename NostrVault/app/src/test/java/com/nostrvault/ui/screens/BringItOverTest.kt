package com.nostrvault.ui.screens

import com.nostrvault.fips.DeviceRole
import com.nostrvault.relay.MacSyncStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Setup's "Copy from my other vault" (plan §5a): its words and when the copy gives up. */
class BringItOverTest {
    @Test
    fun onlyAMacIsCopiedFrom() {
        assertTrue(BringItOver.copiesFrom(DeviceRole.MAC))
        assertFalse(BringItOver.copiesFrom(DeviceRole.PHONE))
        assertFalse(BringItOver.copiesFrom(DeviceRole.HOME_VAULT))
        assertFalse(BringItOver.copiesFrom(DeviceRole.BROWSER))
    }

    private val linked = 1_000L
    private fun status(state: String?, posts: Int? = null, started: Long = linked + 30) =
        MacSyncStatus(state = state, posts = posts, startedAt = started, updatedAt = started)

    @Test
    fun theCopyEndsDoneOrFallsBack() {
        assertEquals(BringItOver.Copy.Done(4200), BringItOver.judge(status("done", 4200), linked, linked, linked + 60))
        assertEquals(BringItOver.Copy.Stalled, BringItOver.judge(status("failed"), linked, linked, linked + 60))
        assertEquals(BringItOver.Copy.Done(12), BringItOver.judge(status("incomplete", 12), linked, linked, linked + 60))
        assertEquals(BringItOver.Copy.Stalled, BringItOver.judge(status("incomplete", 0), linked, linked, linked + 60))
    }

    @Test
    fun twoMinutesWithoutProgressIsAStall() {
        val running = status("running", 300)
        assertEquals(BringItOver.Copy.Going, BringItOver.judge(running, linked, linked + 100, linked + 200))
        assertEquals(BringItOver.Copy.Stalled, BringItOver.judge(running, linked, linked + 100, linked + 221))
        assertEquals("nothing at all for 2 minutes", BringItOver.Copy.Stalled, BringItOver.judge(null, linked, linked, linked + 121))
        assertEquals(BringItOver.Copy.Going, BringItOver.judge(null, linked, linked, linked + 120))
    }

    @Test
    fun aStatusFromBeforeTheLinkIsNotThisCopy() {
        val old = status("done", 99, started = linked - 600)
        assertEquals(BringItOver.Copy.Going, BringItOver.judge(old, linked, linked, linked + 10))
        assertEquals(BringItOver.Copy.Stalled, BringItOver.judge(old, linked, linked, linked + 121))
    }

    @Test
    fun logensWordsForTheThirdOption() {
        assertEquals("Copy from my other vault", BringItOver.COPY)
        assertEquals("Your Mac or another device signed in as you. Scan two codes and it copies over the mesh.", BringItOver.COPY_DETAIL)
    }

    /** The approved small print is the one line that says "mesh"; nothing else on these screens does. */
    @Test
    fun noMeshWordsOnTheseScreens() {
        val words = listOf(
            BringItOver.COPY, BringItOver.CANCEL, BringItOver.SCAN_TITLE, BringItOver.SCAN_BODY, BringItOver.FALLBACK_LINE,
            BringItOver.showCodeTitle("Mac"), BringItOver.showCodeBody("Mac"), BringItOver.linkedLine("Mac"),
            com.nostrvault.fips.MeshPairing.roleConfirmText(DeviceRole.MAC, "Logen's Mac", setup = true),
        )
        for (w in words) for (banned in listOf("mesh", "fips", "npub", "address", "role")) {
            assertFalse("\"$banned\" in: $w", w.lowercase().contains(banned))
        }
    }

    @Test
    fun copyingLine() {
        assertEquals("Copying from Mac…", BringItOver.copyingLine("Mac", null))
        assertEquals("Copying from Mac… 3,412 notes so far", BringItOver.copyingLine("Mac", 3412))
    }
}
