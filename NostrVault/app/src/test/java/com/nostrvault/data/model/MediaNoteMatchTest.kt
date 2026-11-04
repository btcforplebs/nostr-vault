package com.nostrvault.data.model

import com.nostrvault.service.NostrEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The Vault media viewer's swipe up: every note on the vault that uses a file. iOS: MediaNoteMatchTests. */
class MediaNoteMatchTest {
    private val sha = "ab".repeat(32)
    private val url = "https://blossom.example/$sha.jpg"

    private fun note(id: String, kind: Int = 1, at: Long, content: String = "", tags: List<List<String>> = emptyList()) =
        NostrEvent(id = id, pubkey = "p", createdAt = at, kind = kind, tags = tags, content = content, sig = "")

    @Test fun theHashIsReadFromABlossomNameWithOrWithoutItsExtension() {
        assertEquals(sha, MediaNoteMatch.sha256Of(url))
        assertEquals(sha, MediaNoteMatch.sha256Of("https://b.example/${sha.uppercase()}"))
        assertNull(MediaNoteMatch.sha256Of("https://img.example/photo.jpg"))
    }

    @Test fun everyNoteNamingTheFileByUrlHashOrImetaNewestFirst() {
        val mirror = "https://mirror.example/$sha.png"
        val found = MediaNoteMatch.notesUsing(listOf(
            note("byURL", at = 10, content = "look $url"),
            note("byMirror", at = 30, content = "same file elsewhere $mirror"),
            note("byImeta", kind = 20, at = 20, tags = listOf(listOf("imeta", "url $mirror", "x $sha"))),
            note("byX", kind = 1063, at = 25, tags = listOf(listOf("x", sha))),
            note("unrelated", at = 40, content = "https://img.example/other.jpg"),
            note("reaction", kind = 7, at = 50, content = url),
            note("byURL", at = 10, content = "look $url"),
        ), url)
        assertEquals(listOf("byMirror", "byX", "byImeta", "byURL"), found.map { it.id })
    }

    @Test fun aFileWithoutAHashMatchesByItsUrlOnly() {
        val plain = "https://img.example/photo.jpg"
        val found = MediaNoteMatch.notesUsing(listOf(
            note("yes", at = 1, content = "https://IMG.example/photo.jpg"),
            note("no", at = 2, content = "https://img.example/photo2.jpeg"),
        ), plain)
        assertEquals(listOf("yes"), found.map { it.id })
    }
}
