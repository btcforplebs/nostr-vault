package com.nostrvault.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The Media tab orders by the note that posted a file first, as iOS does. */
class MediaPostDateTest {
    private val oldPost = "a".repeat(64)
    private val newPost = "b".repeat(64)
    private val noNote = "c".repeat(64)

    private fun item(hash: String, uploaded: Long?, mtimeMs: Long?, postedAt: Long? = null) = BlossomMediaItem(
        sha256 = hash, displayUrl = "/vault/$hash", localFile = null, mimeType = "image",
        size = 1, uploaded = uploaded, lastModified = mtimeMs, isLocal = true, postedAt = postedAt,
    )

    @Test
    fun `the post date wins over upload time and file time`() {
        assertEquals(100L, item(oldPost, uploaded = 9_000, mtimeMs = 9_000_000, postedAt = 100).sortTime)
    }

    @Test
    fun `without a post date it falls back to upload time, then file time`() {
        assertEquals(500L, item(noNote, uploaded = 500, mtimeMs = 9_000_000).sortTime)
        assertEquals(9_000L, item(noNote, uploaded = null, mtimeMs = 9_000_000).sortTime)
    }

    @Test
    fun `post dates are applied by hash and leave the rest alone`() {
        val items = listOf(item(oldPost, 9_000, null), item(noNote, 500, null))
        val out = withPostDates(items, mapOf(oldPost to 100L))
        assertEquals(100L, out[0].postedAt)
        assertNull(out[1].postedAt)
    }

    @Test
    fun `an old post copied to the phone today sorts below a newer post`() {
        // oldPost was mirrored just now (fresh upload + file time); newPost was posted later than oldPost.
        val items = listOf(
            item(oldPost, uploaded = 10_000, mtimeMs = 10_000_000),
            item(newPost, uploaded = 2_100, mtimeMs = 2_100_000),
        )
        val dated = withPostDates(items, mapOf(oldPost to 1_000L, newPost to 2_000L))
        assertEquals(listOf(newPost, oldPost), MediaSortOption.NEWEST_FIRST.sorted(dated).map { it.sha256 })
        assertEquals(listOf(oldPost, newPost), MediaSortOption.OLDEST_FIRST.sorted(dated).map { it.sha256 })
    }
}
