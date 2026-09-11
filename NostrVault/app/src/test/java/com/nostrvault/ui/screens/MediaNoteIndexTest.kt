package com.nostrvault.ui.screens

import com.nostrvault.data.model.FeedNote
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.Date

private const val HASH_A = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"
private const val HASH_B = "0f9e8d7c6b5a49382716f5e4d3c2b1a00f9e8d7c6b5a49382716f5e4d3c2b1a0"

private fun note(id: String, at: Long, media: List<String>) = FeedNote(
    id = id,
    pubkey = "pub",
    content = "",
    createdAt = Date(at),
    tags = emptyList(),
    kind = 1,
    isReply = false,
    replyToPubkey = null,
    parentEventId = null,
    mediaURLs = media,
    linkURLs = emptyList(),
    quotedEventIds = emptyList(),
    repostedEventId = null,
)

class MediaNoteIndexTest {

    @Test
    fun `pulls the sha256 out of a blossom url`() {
        assertEquals(HASH_A, blobHashInUrl("https://blossom.example/$HASH_A"))
        assertEquals(HASH_A, blobHashInUrl("https://blossom.example/$HASH_A.jpg"))
        assertEquals(HASH_A, blobHashInUrl("https://blossom.example/$HASH_A?auth=x"))
        assertEquals(HASH_A, blobHashInUrl("https://blossom.example/$HASH_A#frag"))
    }

    @Test
    fun `uppercase hashes normalise, so a url and a blob list agree`() {
        assertEquals(HASH_A, blobHashInUrl("https://blossom.example/${HASH_A.uppercase()}"))
    }

    @Test
    fun `a url with no hash yields nothing`() {
        assertNull(blobHashInUrl("https://example.com/photo.jpg"))
        assertNull(blobHashInUrl("https://example.com/"))
    }

    @Test
    fun `a hex run longer than 64 is not a sha256`() {
        // Guards the boundary assertions in the regex. Without them this would
        // match a 64-char window inside a longer hex string and index a blob
        // that does not exist.
        assertNull(blobHashInUrl("https://example.com/${"a".repeat(70)}"))
    }

    @Test
    fun `indexes every blob a note references`() {
        val index = noteIdsByBlobHash(
            listOf(note("n1", 1000L, listOf("https://b/$HASH_A.png", "https://b/$HASH_B.png"))),
        )
        assertEquals(mapOf(HASH_A to "n1", HASH_B to "n1"), index)
    }

    @Test
    fun `the oldest note wins when two reference the same blob`() {
        val index = noteIdsByBlobHash(
            listOf(
                note("newer", 5000L, listOf("https://b/$HASH_A")),
                note("older", 1000L, listOf("https://mirror/$HASH_A")),
            ),
        )
        assertEquals("older", index[HASH_A])
    }

    @Test
    fun `input order does not change the answer`() {
        val a = note("newer", 5000L, listOf("https://b/$HASH_A"))
        val b = note("older", 1000L, listOf("https://mirror/$HASH_A"))
        assertEquals(noteIdsByBlobHash(listOf(a, b)), noteIdsByBlobHash(listOf(b, a)))
    }

    @Test
    fun `same-second ties break on id, not arrival order`() {
        val a = note("zzz", 1000L, listOf("https://b/$HASH_A"))
        val b = note("aaa", 1000L, listOf("https://b/$HASH_A"))
        assertEquals("aaa", noteIdsByBlobHash(listOf(a, b))[HASH_A])
        assertEquals("aaa", noteIdsByBlobHash(listOf(b, a))[HASH_A])
    }

    @Test
    fun `notes with no blossom media contribute nothing`() {
        assertEquals(
            emptyMap<String, String>(),
            noteIdsByBlobHash(listOf(note("n1", 1L, listOf("https://example.com/cat.gif")))),
        )
    }
}
