package com.nostrvault.fips

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * The fileNote lane of the home-vault queue (plan gap 1): one item per blob, signed at send time, old queues still
 * read. Case for case with Apple's HomeVaultFileNoteLaneTests.swift.
 */
class HomeVaultFileNoteLaneTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private val sha = "ab".repeat(32)
    private val other = "cd".repeat(32)

    private fun draft(action: String, sha: String = this.sha) =
        HomeVaultQueue.FileNoteDraft(action, sha, "image/jpeg", 7, listOf("https://nostr.build"))

    private fun queue(dir: File = tmp.newFolder()) = HomeVaultQueue(dir)

    @Test
    fun `an item carries the draft, not a signed event`() {
        val q = queue()
        assertTrue(q.addFileNote(draft(HomeVaultQueue.FileNoteDraft.ADD), now = 1_000))
        val i = q.items().single()
        assertEquals(HomeVaultQueue.TYPE_FILE_NOTE, i.type)
        assertEquals(HomeVaultQueue.fileNoteKey(sha), i.key)
        assertNull("signed at send time, not when queued", i.eventJson)
        assertEquals(HomeVaultQueue.FileNoteDraft.ADD, i.fileNote?.action)
    }

    @Test
    fun `round trips through the file on disk`() {
        val dir = tmp.newFolder()
        queue(dir).apply {
            addFileNote(draft(HomeVaultQueue.FileNoteDraft.ADD))
            addFileNote(draft(HomeVaultQueue.FileNoteDraft.DELETE, sha = other))
        }
        val again = queue(dir).items()
        assertEquals(listOf(draft(HomeVaultQueue.FileNoteDraft.ADD), draft(HomeVaultQueue.FileNoteDraft.DELETE, sha = other)), again.map { it.fileNote })
    }

    @Test
    fun `an old queue still decodes`() {
        val dir = tmp.newFolder()
        File(dir, "queue.json").writeText("""[{"key":"$sha","type":"blob","contentType":"image/jpeg","queuedAt":0,"attempts":2}]""")
        val items = queue(dir).items()
        assertEquals(1, items.size)
        assertNull(items[0].fileNote)
    }

    @Test
    fun `a delete replaces a waiting add for the same blob`() {
        val q = queue()
        q.addFileNote(draft(HomeVaultQueue.FileNoteDraft.ADD))
        q.addFileNote(draft(HomeVaultQueue.FileNoteDraft.DELETE))
        assertEquals(listOf(HomeVaultQueue.FileNoteDraft.DELETE), q.items().map { it.fileNote?.action })
    }

    @Test
    fun `an add replaces a waiting delete`() {
        val q = queue()
        q.addFileNote(draft(HomeVaultQueue.FileNoteDraft.DELETE))
        q.addFileNote(draft(HomeVaultQueue.FileNoteDraft.ADD))
        assertEquals(listOf(HomeVaultQueue.FileNoteDraft.ADD), q.items().map { it.fileNote?.action })
    }

    @Test
    fun `the same add twice is queued once`() {
        val q = queue()
        q.addFileNote(draft(HomeVaultQueue.FileNoteDraft.ADD))
        q.addFileNote(draft(HomeVaultQueue.FileNoteDraft.ADD))
        assertEquals(1, q.size)
    }

    @Test
    fun `other items are kept, and a blob's own item is not taken for its note`() {
        val q = queue()
        q.addBlob(sha, "image/jpeg", 3) { it.writeBytes(byteArrayOf(1, 2, 3)) }
        assertTrue(q.addFileNote(draft(HomeVaultQueue.FileNoteDraft.DELETE)))
        assertEquals(listOf(HomeVaultQueue.TYPE_BLOB, HomeVaultQueue.TYPE_FILE_NOTE), q.items().map { it.type })
    }

    @Test
    fun `forgetting a deleted blob keeps its delete note`() {
        val q = queue()
        q.addBlob(sha, "image/jpeg", 3) { it.writeBytes(byteArrayOf(1, 2, 3)) }
        q.addFileNote(draft(HomeVaultQueue.FileNoteDraft.DELETE))
        q.dropDeleted(sha256 = sha)
        assertEquals("the blob send goes; the kind 5 for it must still go", listOf(HomeVaultQueue.TYPE_FILE_NOTE), q.items().map { it.type })
    }

    @Test
    fun `a file note needs no person to sign`() {
        val q = queue()
        q.addFileNote(draft(HomeVaultQueue.FileNoteDraft.ADD))
        assertFalse("the device mesh key signs it", HomeVaultRules.needsOwnerSignature(q.items().single()))
        val held = HomeVaultRules.select(q.items(), now = 0, userInitiated = false, localSigner = false, needsSignature = HomeVaultRules::needsOwnerSignature)
        assertEquals("a bunker or Amber never holds a file note back", 1, held.toTry.size)
        assertFalse(held.heldForSigner)
    }

    @Test
    fun `a full queue takes no new note`() {
        val q = HomeVaultQueue(tmp.newFolder(), maxItems = 1)
        assertTrue(q.addFileNote(draft(HomeVaultQueue.FileNoteDraft.ADD)))
        assertFalse(q.addFileNote(draft(HomeVaultQueue.FileNoteDraft.ADD, sha = other)))
        assertTrue("replacing its own blob's note is not a new item", q.addFileNote(draft(HomeVaultQueue.FileNoteDraft.DELETE)))
    }

    @Test
    fun `notes do not count toward the blob cap, and blobs not toward the note cap`() {
        val q = HomeVaultQueue(tmp.newFolder(), maxItems = 1)
        assertTrue(q.addFileNote(draft(HomeVaultQueue.FileNoteDraft.ADD)))
        assertTrue("a waiting note leaves the blob slot free", q.addBlob(sha, "image/png", 1) { it.writeText("x") })
        assertFalse("blobs and events still share their cap", q.addEvent("e1", "{}"))
        assertFalse("notes keep a cap of their own", q.addFileNote(draft(HomeVaultQueue.FileNoteDraft.ADD, sha = other)))
        assertEquals(2, q.size)
    }

    @Test
    fun `only the home vault taking the delete sends the device kind 5`() {
        val home = "npub1home"
        val homeKey = MeshDeleteTarget(home, "").key
        val mac = MeshDeleteTarget("npub1mac", "").key
        assertTrue(MeshDeleteTargets.homeVaultTookIt(home, listOf("https://m.example" to true, homeKey to true)))
        assertFalse("a mirror took it, the vault kept it", MeshDeleteTargets.homeVaultTookIt(home, listOf("https://m.example" to true, homeKey to false)))
        assertFalse("a Mac took it, the vault kept it", MeshDeleteTargets.homeVaultTookIt(home, listOf(mac to true, homeKey to false)))
        assertFalse("the vault was never asked", MeshDeleteTargets.homeVaultTookIt(home, listOf("https://m.example" to true)))
        assertFalse("no home vault", MeshDeleteTargets.homeVaultTookIt(null, listOf(homeKey to true)))
    }

    // The mesh key signs /files events only (Tron T2: no general signing function).

    @Test
    fun `the mesh key signs only files events`() {
        assertTrue(MeshKeySigner.fileNotesAllowed(1063, emptyList()))
        assertTrue(MeshKeySigner.fileNotesAllowed(5, listOf(listOf("e", "n1"), listOf("k", "1063"))))
        assertFalse("a kind 5 for a post", MeshKeySigner.fileNotesAllowed(5, listOf(listOf("e", "n1"))))
        assertFalse(MeshKeySigner.fileNotesAllowed(5, listOf(listOf("k", "1063"), listOf("k", "1"))))
        assertTrue(MeshKeySigner.fileNotesAllowed(22242, listOf(listOf("relay", "ws://npub1v.fips/files"), listOf("challenge", "c"))))
        assertFalse("an AUTH for the vault's main relay", MeshKeySigner.fileNotesAllowed(22242, listOf(listOf("relay", "ws://npub1v.fips/"), listOf("challenge", "c"))))
        assertFalse(MeshKeySigner.fileNotesAllowed(1, emptyList()))
        assertFalse(MeshKeySigner.fileNotesAllowed(24242, emptyList()))
    }
}
