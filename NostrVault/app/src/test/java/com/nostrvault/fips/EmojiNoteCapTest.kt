package com.nostrvault.fips

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Tron's PR 2024 M1: emoji notes have their own cap, so a Save copies run never fills the photo notes' lane. */
class EmojiNoteCapTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private fun sha(i: Int) = "%064x".format(i)

    private fun emoji(i: Int) = HomeVaultQueue.FileNoteDraft(
        HomeVaultQueue.FileNoteDraft.EMOJI, sha(i), "image/png", 7, emptyList(), listOf(listOf("e$i", "https://x.example/$i.png")), emptyList(),
    )

    private fun plain(i: Int) = HomeVaultQueue.FileNoteDraft(HomeVaultQueue.FileNoteDraft.ADD, sha(i), "image/png", 7)

    @Test
    fun `a full emoji lane still takes photo notes, and a full photo lane still takes emoji notes`() {
        val q = HomeVaultQueue(tmp.newFolder(), maxItems = 3, maxEmojiNotes = 5)
        val queued = q.addFileNotes((1..8).map(::emoji))
        assertEquals((1..5).map(::sha).toSet(), queued)
        assertTrue("photo note after a full emoji lane", q.addFileNote(plain(100)))
        assertTrue(q.addFileNote(plain(101)))
        assertTrue(q.addFileNote(plain(102)))
        assertFalse("photo lane full", q.addFileNote(plain(103)))
        assertFalse("emoji lane full", q.addFileNote(emoji(9)))
        assertTrue("already waiting counts as queued", q.addFileNote(emoji(1)))
        assertEquals(8, q.items().size)
    }

    @Test
    fun `a batch of 300 emoji notes survives the queue file`() {
        val dir = tmp.newFolder()
        HomeVaultQueue(dir).addFileNotes((1..300).map(::emoji))
        assertEquals(300, HomeVaultQueue(dir).items().count { it.fileNote?.action == HomeVaultQueue.FileNoteDraft.EMOJI })
    }
}
