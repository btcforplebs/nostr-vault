package com.nostrvault.ui.screens

import android.os.FileObserver
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File

class MediaLiveRulesTest {
    private val sha = "a".repeat(64)
    private val other = "b".repeat(64)

    private fun local(hash: String, mtime: Long, mime: String? = "image") = BlossomMediaItem(
        sha256 = hash, displayUrl = "/vault/blossom/$hash", localFile = File("/vault/blossom/$hash"),
        mimeType = mime, size = 10, uploaded = null, lastModified = mtime, isLocal = true,
    )

    private fun remote(hash: String, uploaded: Long, mime: String? = "image/jpeg") = BlossomMediaItem(
        sha256 = hash, displayUrl = "https://media.example/$hash", localFile = null,
        mimeType = mime, size = 10, uploaded = uploaded, lastModified = null, isLocal = false, noteId = "note1",
    )

    @Test
    fun `a stored blob is its hash, bare or with an extension`() {
        assertEquals(sha, MediaLiveRules.blobHash(sha))
        assertEquals(sha, MediaLiveRules.blobHash("$sha.jpg"))
    }

    @Test
    fun `part-written, set-aside and other files are not blobs`() {
        assertNull(MediaLiveRules.blobHash(null))
        assertNull(MediaLiveRules.blobHash("$sha.x7f3.tmp"))
        assertNull(MediaLiveRules.blobHash("upload.123.tmp"))
        assertNull(MediaLiveRules.blobHash("$sha.corrupt"))
        assertNull(MediaLiveRules.blobHash("$sha.tmp"))
        assertNull(MediaLiveRules.blobHash("A".repeat(64)))
        assertNull(MediaLiveRules.blobHash("a".repeat(63)))
    }

    @Test
    fun `the relay's rename into place and a direct write are landings, a delete or move away is a removal`() {
        assertEquals(MediaLiveRules.Change.Landed(sha), MediaLiveRules.change(FileObserver.MOVED_TO, sha))
        assertEquals(MediaLiveRules.Change.Landed(sha), MediaLiveRules.change(FileObserver.CLOSE_WRITE, sha))
        assertEquals(MediaLiveRules.Change.Removed(sha), MediaLiveRules.change(FileObserver.DELETE, sha))
        assertEquals(MediaLiveRules.Change.Removed(sha), MediaLiveRules.change(FileObserver.MOVED_FROM, sha))
        assertNull(MediaLiveRules.change(FileObserver.MOVED_TO, "$sha.x7f3.tmp"))
        assertNull(MediaLiveRules.change(FileObserver.CLOSE_WRITE, "$sha.x7f3.tmp"))
        assertNull(MediaLiveRules.change(FileObserver.OPEN, sha))
    }

    @Test
    fun `a new file goes on top, as a new note does in the feed`() {
        val list = listOf(local(other, mtime = 1_000_000))
        val out = MediaLiveRules.landed(list, local(sha, mtime = 9_000_000))
        assertEquals(listOf(sha, other), out.map { it.sha256 })
    }

    @Test
    fun `a file that was only on a server becomes this phone's copy and keeps the server's facts`() {
        val list = listOf(remote(sha, uploaded = 500))
        val out = MediaLiveRules.landed(list, local(sha, mtime = 9_000_000))
        assertEquals(1, out.size)
        val item = out.single()
        assertEquals(true, item.isLocal)
        assertEquals("/vault/blossom/$sha", item.displayUrl)
        assertEquals(500L, item.uploaded)
        assertEquals("image/jpeg", item.mimeType)
        assertEquals("note1", item.noteId)
    }

    @Test
    fun `the same file landing twice is one tile`() {
        val once = MediaLiveRules.landed(emptyList(), local(sha, mtime = 1_000))
        val twice = MediaLiveRules.landed(once, local(sha, mtime = 2_000))
        assertEquals(1, twice.size)
    }

    @Test
    fun `a file the Media tab does not show stays out`() {
        val out = MediaLiveRules.landed(emptyList(), local(sha, mtime = 1_000, mime = "application/pdf"))
        assertEquals(emptyList<BlossomMediaItem>(), out)
    }

    @Test
    fun `a deleted copy leaves the list, a server-only tile stays`() {
        val list = listOf(local(sha, mtime = 1_000), remote(other, uploaded = 5))
        assertEquals(listOf(other), MediaLiveRules.removed(list, sha).map { it.sha256 })
        assertEquals(list, MediaLiveRules.removed(list, other))
    }

    @Test
    fun `a copy's date stamp re-reads its tile and moves it down to that date`() {
        assertEquals(MediaLiveRules.Change.Landed(sha), MediaLiveRules.change(FileObserver.ATTRIB, sha))
        val landedNow = listOf(local(sha, mtime = 9_000_000), local(other, mtime = 5_000_000))
        val stamped = MediaLiveRules.landed(landedNow, local(sha, mtime = 1_000_000))
        assertEquals(listOf(other, sha), stamped.map { it.sha256 })
    }
}
