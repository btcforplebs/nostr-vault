package com.nostrvault.data.local

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.UUID

/** Deleted ids survive a restart and stay with their account. Twin: iOS `DeletedNotesStoreTests`. */
class DeletedNotesStoreTest {
    private val dir = File(System.getProperty("java.io.tmpdir"), "deleted-notes-${UUID.randomUUID()}")

    @After
    fun tearDown() {
        dir.deleteRecursively()
    }

    @Test
    fun `marked ids come back from disk`() {
        DeletedNotesStore(dir).markDeleted(setOf("a1", "b2"), "acct")
        val reopened = DeletedNotesStore(dir)
        assertEquals(setOf("a1", "b2"), reopened.ids("acct"))
        assertTrue(reopened.contains("a1", "acct"))
    }

    @Test
    fun `accounts are kept apart`() {
        val store = DeletedNotesStore(dir)
        store.markDeleted(setOf("a1"), "one")
        assertFalse(store.contains("a1", "two"))
        assertEquals(emptySet<String>(), store.ids("two"))
    }

    @Test
    fun `marking again adds to what is there`() {
        val store = DeletedNotesStore(dir)
        store.markDeleted(setOf("a1"), "acct")
        store.markDeleted(setOf("a1", "c3"), "acct")
        assertEquals(setOf("a1", "c3"), DeletedNotesStore(dir).ids("acct"))
    }

    @Test
    fun `nothing to mark writes nothing`() {
        val store = DeletedNotesStore(dir)
        store.markDeleted(emptySet(), "acct")
        assertFalse(store.file("acct").exists())
    }
}
