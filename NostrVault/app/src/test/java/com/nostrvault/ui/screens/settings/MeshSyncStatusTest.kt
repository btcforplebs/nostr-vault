package com.nostrvault.ui.screens.settings

import com.nostrvault.fips.DeviceRole
import com.nostrvault.fips.MeshCopyV2
import com.nostrvault.fips.MeshSyncState
import com.nostrvault.fips.MyDevice
import com.nostrvault.ui.screens.settings.MeshSyncStatus.State
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MeshSyncStatusTest {
    private val now = 1_767_000_000L
    private val mac = MyDevice("npub1mac", DeviceRole.MAC, "Studio Mac", inReach = true, lastSeen = now)
    private val box = MyDevice("npub1box", DeviceRole.HOME_VAULT, "", inReach = false, lastSeen = 0)
    private val phone = MyDevice("npub1phone", DeviceRole.PHONE, "Pixel", inReach = true, lastSeen = now)

    @Test
    fun `only devices copied from get a row, in the list's order`() {
        val sync = MeshSyncState(lastAt = mapOf("npub1box" to now - 300, "npub1mac" to now - 7200, "npub1gone" to now))
        val rows = MeshSyncStatus.rows(listOf(mac, box, phone), sync, null, now)
        assertEquals(listOf("Studio Mac", DeviceRole.HOME_VAULT.label), rows.map { it.name })
        assertEquals(listOf("Last synced 2 h ago", "Last synced 5 min ago"), rows.map { it.lastLine })
        assertEquals(listOf(State.UP_TO_DATE, State.UP_TO_DATE), rows.map { it.state })
    }

    @Test
    fun `the state follows running, waiting and failed`() {
        val sync = MeshSyncState(
            lastAt = mapOf("npub1mac" to now, "npub1box" to now, "npub1phone" to now),
            running = "npub1mac", queued = listOf("npub1box"), failed = mapOf("npub1phone" to "unreachable", "npub1mac" to "x"),
        )
        assertEquals(State.SYNCING, MeshSyncStatus.state("npub1mac", sync))
        assertEquals(State.WAITING, MeshSyncStatus.state("npub1box", sync))
        assertEquals(State.FAILED, MeshSyncStatus.state("npub1phone", sync))
    }

    @Test
    fun `state lines`() {
        val fetching = MeshCopyV2.Line("fetching", "media", 25L to 100L, 0L to 1L, "mesh", "")
        assertEquals("Syncing… 25%", MeshSyncStatus.stateLine(State.SYNCING, null, fetching))
        assertEquals("Syncing…", MeshSyncStatus.stateLine(State.SYNCING, null, null))
        assertTrue(MeshSyncStatus.stateLine(State.FAILED, "unreachable", null).startsWith("Couldn't reach it"))
        assertEquals("The last sync didn't finish.", MeshSyncStatus.stateLine(State.FAILED, "hash_mismatch", null))
        assertEquals("Never synced", MeshSyncStatus.lastLine(0, now))
    }

    @Test
    fun `sync now is off before setup, with nothing to sync, or while one runs or waits`() {
        val sync = MeshSyncState(lastAt = mapOf("npub1mac" to now))
        val rows = MeshSyncStatus.rows(listOf(mac), sync, null, now)
        assertTrue(MeshSyncStatus.syncEnabled(true, rows, sync))
        assertFalse(MeshSyncStatus.syncEnabled(false, rows, sync))
        assertFalse(MeshSyncStatus.syncEnabled(true, emptyList(), sync))
        assertFalse(MeshSyncStatus.syncEnabled(true, rows, sync.copy(running = "npub1mac")))
        assertFalse(MeshSyncStatus.syncEnabled(true, rows, sync.copy(queued = listOf("npub1mac"))))
    }
}
