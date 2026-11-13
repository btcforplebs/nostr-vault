package com.nostrvault.data.local

import kotlinx.serialization.Serializable
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class VaultSnapshotStoreTest {
    @get:Rule val tmp = TemporaryFolder()

    @Serializable
    data class Item(val id: String, val at: Long)

    private val alice = "a".repeat(64)
    private val bob = "b".repeat(64)
    private val day = 24 * 60 * 60 * 1000L

    @Test
    fun `each account reads back its own saved screen`() {
        val store = VaultSnapshotStore(tmp.root)
        store.write("vault-notes", alice, listOf(Item("a1", 1), Item("a2", 2)), Item.serializer(), now = 1_000) { it.at }
        store.write("vault-notes", bob, listOf(Item("b1", 5)), Item.serializer(), now = 1_000) { it.at }

        assertEquals(listOf(Item("a2", 2), Item("a1", 1)), store.read("vault-notes", alice, Item.serializer(), day, now = 2_000))
        assertEquals(listOf(Item("b1", 5)), store.read("vault-notes", bob, Item.serializer(), day, now = 2_000))
        // Another list of the same account is separate.
        assertNull(store.read("vault-activity", alice, Item.serializer(), day, now = 2_000))
    }

    @Test
    fun `the saved screen keeps only the newest`() {
        val store = VaultSnapshotStore(tmp.root)
        val many = (1..1_000).map { Item("e$it", it.toLong()) }
        store.write("vault-activity", alice, many, Item.serializer()) { it.at }
        val back = store.read("vault-activity", alice, Item.serializer(), day)!!
        assertEquals(400, back.size)
        assertEquals(1_000L, back.first().at)
    }

    @Test
    fun `a saved screen past its age is dropped`() {
        val store = VaultSnapshotStore(tmp.root)
        store.write("vault-notes", alice, listOf(Item("a1", 1)), Item.serializer(), now = 0) { it.at }
        assertNull(store.read("vault-notes", alice, Item.serializer(), day, now = day + 1))
        assertFalse(File(tmp.root, "vault-snapshots/vault-notes-$alice.json").exists())
    }

    @Test
    fun `a malformed account writes and reads nothing`() {
        val store = VaultSnapshotStore(tmp.root)
        store.write("vault-notes", "../evil", listOf(Item("x", 1)), Item.serializer()) { it.at }
        assertNull(store.read("vault-notes", "../evil", Item.serializer(), day))
        assertEquals(emptyList<String>(), tmp.root.walkTopDown().filter { it.isFile }.map { it.name }.toList())
    }

    @Test
    fun `a broken file reads as none`() {
        val store = VaultSnapshotStore(tmp.root)
        File(tmp.root, "vault-snapshots").mkdirs()
        File(tmp.root, "vault-snapshots/vault-notes-$alice.json").writeText("{not json")
        assertNull(store.read("vault-notes", alice, Item.serializer(), day))
    }
}
