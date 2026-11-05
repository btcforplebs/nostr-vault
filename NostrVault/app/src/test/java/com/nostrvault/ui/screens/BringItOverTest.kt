package com.nostrvault.ui.screens

import com.nostrvault.fips.DeviceRole
import com.nostrvault.relay.MacSyncStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Setup's "Already using Nostr Vault on another device?" (plan §5a): where it sits and when the copy gives up. */
class BringItOverTest {
    private val useNostr = listOf(
        WizardStep.WELCOME, WizardStep.RELAY_CHOICE, WizardStep.USE_NOSTR_KEY, WizardStep.REFERRER,
        WizardStep.BACKUP_QUESTION, WizardStep.RELAY_CHECK, WizardStep.IMPORT_TOUR,
    )

    @Test
    fun askedAfterTheKeyAndReferrerBeforeTheBackupQuestion() {
        val steps = BringItOver.withStep(useNostr, SetupPath.USE_NOSTR, readOnly = false)
        assertEquals(
            listOf(WizardStep.USE_NOSTR_KEY, WizardStep.REFERRER, WizardStep.OTHER_DEVICE, WizardStep.BACKUP_QUESTION),
            steps.subList(2, 6),
        )
    }

    @Test
    fun notAskedReadOnlyOrOnOtherPaths() {
        assertEquals(useNostr, BringItOver.withStep(useNostr, SetupPath.USE_NOSTR, readOnly = true))
        assertEquals(useNostr, BringItOver.withStep(useNostr, SetupPath.NEW_TO_NOSTR, readOnly = false))
        val noImport = useNostr - WizardStep.BACKUP_QUESTION
        assertEquals("no relay import to replace (external relay)", noImport, BringItOver.withStep(noImport, SetupPath.USE_NOSTR, readOnly = false))
    }

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
    fun noMeshWordsOnTheseScreens() {
        val words = listOf(
            BringItOver.QUESTION, BringItOver.YES, BringItOver.YES_DETAIL, BringItOver.NO, BringItOver.NO_DETAIL,
            BringItOver.SCAN_TITLE, BringItOver.SCAN_BODY, BringItOver.FALLBACK_LINE,
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
