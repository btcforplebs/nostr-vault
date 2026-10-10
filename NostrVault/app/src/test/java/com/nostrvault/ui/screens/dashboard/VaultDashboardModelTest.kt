package com.nostrvault.ui.screens.dashboard

import com.nostrvault.ui.screens.dashboard.VaultDashboardModel.RunState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Vault Dashboard (v2) wording and numbers, as iOS VaultDashboardView. */
class VaultDashboardModelTest {

    private val m = VaultDashboardModel
    private val now = 1_700_000_000_000L
    private fun ago(seconds: Long) = now - seconds * 1000

    @Test
    fun `run state puts a problem first`() {
        assertEquals(RunState.NEEDS_FIX, m.runState(isBooting = true, isRunning = true, isImporting = false, isLocked = true, isPortConflict = false))
        assertEquals(RunState.NEEDS_FIX, m.runState(false, false, false, false, isPortConflict = true))
        assertEquals(RunState.STARTING, m.runState(isBooting = true, isRunning = false, isImporting = false, isLocked = false, isPortConflict = false))
        assertEquals(RunState.IMPORTING, m.runState(false, false, isImporting = true, isLocked = false, isPortConflict = false))
        assertEquals(RunState.PAUSED, m.runState(false, false, false, false, false))
        assertEquals(RunState.RUNNING, m.runState(false, true, false, false, false))
    }

    @Test
    fun `status words`() {
        assertEquals("Your vault is running", m.statusTitle(RunState.RUNNING))
        assertEquals("Your vault is running", m.statusTitle(RunState.IMPORTING))
        assertEquals("Your vault is starting…", m.statusTitle(RunState.STARTING))
        assertEquals("Your vault is paused", m.statusTitle(RunState.PAUSED))
        assertEquals("Your vault needs a restart", m.statusTitle(RunState.NEEDS_FIX))
        assertTrue(m.pulses(RunState.RUNNING))
        assertFalse(m.pulses(RunState.PAUSED))
        assertFalse(m.pulses(RunState.NEEDS_FIX))
    }

    @Test
    fun `problem text and fix button`() {
        assertNull(m.problemText(RunState.RUNNING, false, 3355))
        assertEquals("It isn't saving new notes or messages. Start it to catch up.", m.problemText(RunState.PAUSED, false, 3355))
        assertEquals("Another app is using port 3355. Restarting clears it.", m.problemText(RunState.NEEDS_FIX, true, 3355))
        assertEquals("The last session didn't shut down cleanly. Restarting clears the lock.", m.problemText(RunState.NEEDS_FIX, false, 3355))
        assertEquals("Start vault", m.fixButtonTitle(RunState.PAUSED))
        assertEquals("Restart vault", m.fixButtonTitle(RunState.NEEDS_FIX))
    }

    @Test
    fun `uptime`() {
        assertNull(m.uptime(null, now))
        assertNull(m.uptime(0, now))
        assertEquals("Up 0m", m.uptime(ago(20), now))
        assertEquals("Up 7m", m.uptime(ago(7 * 60 + 5), now))
        assertEquals("Up 4h 12m", m.uptime(ago(4 * 3600 + 12 * 60), now))
        assertEquals("Up 2d 3h", m.uptime(ago(2 * 86_400 + 3 * 3600 + 59), now))
        assertEquals("Up 0m", m.uptime(now + 5_000, now))
    }

    @Test
    fun `relative times read like iOS named presentation`() {
        assertEquals("now", m.relative(ago(5), now))
        assertEquals("1 minute ago", m.relative(ago(60), now))
        assertEquals("5 minutes ago", m.relative(ago(5 * 60), now))
        assertEquals("1 hour ago", m.relative(ago(3600), now))
        assertEquals("3 hours ago", m.relative(ago(3 * 3600), now))
        assertEquals("yesterday", m.relative(ago(86_400), now))
        assertEquals("4 days ago", m.relative(ago(4 * 86_400), now))
        assertEquals("last week", m.relative(ago(8 * 86_400), now))
        assertEquals("3 weeks ago", m.relative(ago(22 * 86_400), now))
        assertEquals("last month", m.relative(ago(40L * 86_400), now))
        assertEquals("5 months ago", m.relative(ago(150L * 86_400), now))
        assertEquals("last year", m.relative(ago(400L * 86_400), now))
        assertEquals("2 years ago", m.relative(ago(800L * 86_400), now))
    }

    @Test
    fun `safety count is out of four`() {
        assertEquals(0, m.safetyDoneCount(false, false, false, false))
        assertEquals(2, m.safetyDoneCount(true, false, true, false))
        assertEquals(4, m.safetyDoneCount(true, true, true, true))
    }

    @Test
    fun `key row words`() {
        assertEquals("Your key is in a signer app", m.keyTitle(usesSigner = true, hasLocalKey = true))
        assertEquals("Your key is on this device", m.keyTitle(false, true))
        assertEquals("No key on this device", m.keyTitle(false, false))
        assertEquals("You can read, but not post or sign.", m.keyDetail(false, false))
    }

    @Test
    fun `safety details`() {
        assertEquals("Not saved yet. If a client wipes it, you can't get it back.", m.followListDetail(null, now))
        assertEquals("Last saved 2 hours ago.", m.followListDetail(ago(7200), now))
        assertEquals("Not set up. Your Mac can keep a copy that's always on.", m.macSyncDetail(false, 123, now))
        assertEquals("Set up. Not synced yet.", m.macSyncDetail(true, null, now))
        assertEquals("Set up. Not synced yet.", m.macSyncDetail(true, 0, now))
        assertEquals("Last synced yesterday.", m.macSyncDetail(true, (now / 1000) - 86_400, now))
        assertEquals("Never made. Keep one somewhere off this phone.", m.backupFileDetail(null, now))
        assertEquals("Last made now.", m.backupFileDetail(now, now))
        assertEquals("Never made.", m.lastMade(null, now))
    }

    @Test
    fun `reach words`() {
        assertEquals("Trust list not built yet", m.trustTitle(0))
        assertEquals("1,234 people can reach your inbox", m.trustTitle(1234))
        assertEquals("People within 1 hop of you. Everyone else is kept out.", m.trustDetail(1))
        assertEquals("People within 3 hops of you. Everyone else is kept out.", m.trustDetail(3))
        assertEquals("Nobody blocked.", m.blockedDetail(0))
        assertEquals("1 person blocked.", m.blockedDetail(1))
        assertEquals("7 people blocked.", m.blockedDetail(7))
    }

    @Test
    fun `tile counts wait for the counts to load`() {
        assertNull(m.messagesCount(emptyMap()))
        assertNull(m.kindCount(emptyMap(), 1))
        assertEquals(5, m.messagesCount(mapOf(4 to 2, 1059 to 3, 1 to 9)))
        assertEquals(0, m.messagesCount(mapOf(1 to 9)))
        assertEquals(0, m.kindCount(mapOf(1 to 9), 30023))
        assertEquals(9, m.kindCount(mapOf(1 to 9), 1))
    }

    @Test
    fun `storage split takes media out of the relay folder`() {
        val split = m.storageSplit(relayDataBytes = 1000, blossomBytes = 300, cacheBytes = 50, thumbnailBytes = 25)
        assertEquals(700, split.notes)
        assertEquals(300, split.media)
        assertEquals(75, split.cache)
        assertEquals(1075, split.total)
        // Sizes read at different moments can disagree; never negative.
        assertEquals(0, m.storageSplit(100, 300, 0, 0).notes)
    }

    @Test
    fun `size says None rather than zero`() {
        assertEquals("None", m.size(0))
        assertEquals("None", m.size(-1))
        assertEquals("512 B", m.size(512))
        assertEquals("1.5 KB", m.size(1536))
        assertEquals("2.0 MB", m.size(2L * 1024 * 1024))
        assertEquals("1.50 GB", m.size(1536L * 1024 * 1024))
    }

    @Test
    fun `import details`() {
        assertEquals("Jan 2023", m.importStartText("2023-01-01"))
        assertEquals("garbage", m.importStartText("garbage"))
        assertEquals("Since Jan 2023. Never ran.", m.importNotesDetail("2023-01-01", null, now))
        assertEquals("Since Mar 2024. Last ran 5 minutes ago.", m.importNotesDetail("2024-03-15", ago(300), now))
        assertEquals("Copies the media in your notes here.", m.importMediaDetail(null, now))
        assertEquals("Last ran yesterday.", m.importMediaDetail(ago(86_400), now))
    }

    @Test
    fun `hops`() {
        assertEquals("1 hop", m.hops(1))
        assertEquals("2 hops", m.hops(2))
    }
}
