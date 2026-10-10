package com.nostrvault.data.local

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The Vault Dashboard's "last ran" times (iOS VaultHistory). */
class VaultHistoryTest {

    private class MemoryStore : VaultHistory.Store {
        val values = mutableMapOf<String, Long>()
        override fun read(key: String): Long? = values[key]
        override fun write(key: String, value: Long) { values[key] = value }
    }

    @Test
    fun `nothing recorded reads as never`() {
        val history = VaultHistory(MemoryStore())
        VaultHistory.Entry.entries.forEach { assertNull(history.last(it)) }
        assertEquals(VaultHistory.Snapshot(), history.state.value)
    }

    @Test
    fun `record stamps the clock and updates state`() {
        val history = VaultHistory(MemoryStore(), clock = { 1_700_000_000_000 })
        history.record(VaultHistory.Entry.NOTES_BACKUP)
        assertEquals(1_700_000_000_000, history.last(VaultHistory.Entry.NOTES_BACKUP))
        assertEquals(1_700_000_000_000, history.state.value.notesBackup)
        assertNull(history.state.value.notesImport)
    }

    @Test
    fun `each entry is kept apart`() {
        val history = VaultHistory(MemoryStore())
        history.record(VaultHistory.Entry.NOTES_IMPORT, at = 1)
        history.record(VaultHistory.Entry.NOTES_BACKUP, at = 2)
        history.record(VaultHistory.Entry.MEDIA_BACKUP, at = 3)
        history.record(VaultHistory.Entry.MEDIA_IMPORT, at = 4)
        assertEquals(VaultHistory.Snapshot(notesImport = 1, notesBackup = 2, mediaBackup = 3, mediaImport = 4), history.state.value)
    }

    @Test
    fun `a later record replaces the earlier one`() {
        val history = VaultHistory(MemoryStore())
        history.record(VaultHistory.Entry.MEDIA_IMPORT, at = 10)
        history.record(VaultHistory.Entry.MEDIA_IMPORT, at = 20)
        assertEquals(20L, history.last(VaultHistory.Entry.MEDIA_IMPORT))
    }

    @Test
    fun `non-positive times are ignored`() {
        val store = MemoryStore()
        val history = VaultHistory(store)
        history.record(VaultHistory.Entry.NOTES_IMPORT, at = 0)
        history.record(VaultHistory.Entry.NOTES_IMPORT, at = -5)
        assertNull(history.last(VaultHistory.Entry.NOTES_IMPORT))
        assertEquals(emptyMap<String, Long>(), store.values)
    }

    @Test
    fun `history survives a relaunch through the store`() {
        val store = MemoryStore()
        VaultHistory(store).record(VaultHistory.Entry.NOTES_BACKUP, at = 42)
        assertEquals(42L, VaultHistory(store).last(VaultHistory.Entry.NOTES_BACKUP))
    }

    @Test
    fun `keys match iOS UserDefaults keys`() {
        assertEquals("haven.vault.lastNotesImport", VaultHistory.Entry.NOTES_IMPORT.key)
        assertEquals("haven.vault.lastNotesBackup", VaultHistory.Entry.NOTES_BACKUP.key)
        assertEquals("haven.vault.lastMediaBackup", VaultHistory.Entry.MEDIA_BACKUP.key)
        assertEquals("haven.vault.lastMediaImport", VaultHistory.Entry.MEDIA_IMPORT.key)
    }

    @Test
    fun `a corrupt zero in the store reads as never`() {
        val store = MemoryStore().apply { values[VaultHistory.Entry.MEDIA_BACKUP.key] = 0 }
        assertNull(VaultHistory(store).last(VaultHistory.Entry.MEDIA_BACKUP))
    }
}
