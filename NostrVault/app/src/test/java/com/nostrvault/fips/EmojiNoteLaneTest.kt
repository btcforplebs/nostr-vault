package com.nostrvault.fips

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** An emoji note waits apart from the blob's plain note, and a newer word for it (more codes) replaces the old one. */
class EmojiNoteLaneTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private val sha = "ab".repeat(32)

    private fun emoji(codes: List<List<String>>) =
        HomeVaultQueue.FileNoteDraft(HomeVaultQueue.FileNoteDraft.EMOJI, sha, "image/png", 7, emptyList(), codes, listOf("30030:${"b".repeat(64)}:x"))

    @Test
    fun `an emoji note and a plain note for one blob both wait`() {
        val q = HomeVaultQueue(tmp.newFolder())
        assertTrue(q.addFileNote(HomeVaultQueue.FileNoteDraft(HomeVaultQueue.FileNoteDraft.ADD, sha, "image/png", 7)))
        assertTrue(q.addFileNote(emoji(listOf(listOf("a", "https://x.example/a.png")))))
        assertEquals(setOf(HomeVaultQueue.fileNoteKey(sha), HomeVaultQueue.emojiNoteKey(sha)), q.items().map { it.key }.toSet())
    }

    @Test
    fun `a newer emoji word replaces the waiting one, the same word is queued once`() {
        val q = HomeVaultQueue(tmp.newFolder())
        val one = emoji(listOf(listOf("a", "https://x.example/a.png")))
        val two = emoji(listOf(listOf("a", "https://x.example/a.png"), listOf("b", "https://x.example/a.png")))
        assertTrue(q.addFileNote(one))
        assertTrue(q.addFileNote(one))
        assertEquals(1, q.items().size)
        assertTrue(q.addFileNote(two))
        assertEquals(two.emojiCodes, q.items().single().fileNote?.emojiCodes)
    }

    @Test
    fun `an emoji draft survives the queue file`() {
        val dir = tmp.newFolder()
        HomeVaultQueue(dir).addFileNote(emoji(listOf(listOf("a", "https://x.example/a.png"))))
        val back = HomeVaultQueue(dir).items().single().fileNote!!
        assertEquals(HomeVaultQueue.FileNoteDraft.EMOJI, back.action)
        assertEquals(listOf("30030:${"b".repeat(64)}:x"), back.emojiSets)
    }
}
