package com.nostrvault.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The viewer's View Note reads [BlossomMediaItem.noteId], which only [withNoteIds] sets. */
class MediaViewerNoteIdTest {
    private fun item(hash: String) = BlossomMediaItem(
        sha256 = hash, displayUrl = "https://m.example/$hash", localFile = null,
        mimeType = "image/png", size = null, uploaded = 1, lastModified = null, isLocal = false,
    )

    private val posted = "a".repeat(64)
    private val unposted = "b".repeat(64)

    @Test
    fun `an item a note posted gets that note, one with none stays without`() {
        val out = withNoteIds(listOf(item(posted), item(unposted)), mapOf(posted to "note1"))
        assertEquals("note1", out[0].noteId)
        assertNull(out[1].noteId)
    }

    @Test
    fun `the index is keyed by lowercase hash, as the long-press menu reads it`() {
        val upper = "C".repeat(64)
        val out = withNoteIds(listOf(item(upper)), mapOf(upper.lowercase() to "note2"))
        assertEquals("note2", out.single().noteId)
    }

    @Test
    fun `order and everything else are kept`() {
        val items = listOf(item(unposted), item(posted))
        val out = withNoteIds(items, mapOf(posted to "n"))
        assertEquals(items.map { it.sha256 }, out.map { it.sha256 })
        assertEquals(items[1].copy(noteId = "n"), out[1])
    }
}
