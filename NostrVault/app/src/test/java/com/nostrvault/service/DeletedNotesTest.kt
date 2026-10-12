package com.nostrvault.service

import com.nostrvault.data.model.FeedNote
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The rules that keep a deleted post gone. Twin: iOS `DeletedNotesTests`. */
class DeletedNotesTest {
    private val owner = "a".repeat(64)
    private val gone = "1".repeat(64)
    private val kept = "2".repeat(64)

    private fun note(id: String, kind: Int = 1, tags: List<List<String>> = emptyList()) =
        FeedNote.fromEvent(id, "b".repeat(64), "text", tags, 1_700_000_000, kind)

    private fun repost(id: String, of: String) =
        FeedNote.fromEvent(id, "c".repeat(64), "", listOf(listOf("e", of)), 1_700_000_000, 6)

    @Test
    fun `a request's e tags are the deleted posts, hex ids only`() {
        val tags = listOf(listOf("e", gone.uppercase()), listOf("e", "not-an-id"), listOf("p", kept), listOf("e"))
        assertEquals(setOf(gone), DeletedNotes.targets(tags))
    }

    @Test
    fun `only the owner's own kind 5 counts`() {
        assertTrue(DeletedNotes.isOwnRequest(5, owner, owner))
        assertFalse(DeletedNotes.isOwnRequest(5, "d".repeat(64), owner))
        assertFalse(DeletedNotes.isOwnRequest(1, owner, owner))
        assertFalse(DeletedNotes.isOwnRequest(5, "", ""))
    }

    private fun request(pubkey: String = owner, kind: Int = 5) = buildJsonObject {
        put("id", "e".repeat(64))
        put("kind", kind)
        put("pubkey", pubkey)
        put("content", "")
        put("sig", "f".repeat(128))
    }

    @Test
    fun `your own signed request counts`() {
        assertTrue(DeletedNotes.isOwnSignedRequest(request(), owner) { true })
    }

    /**
     * A relay in the feed set can send a kind 5 under the owner's pubkey
     * naming any post. With a bad `sig` or a changed `id` it marks nothing.
     */
    @Test
    fun `a request that fails verification marks nothing`() {
        var verified = 0
        assertFalse(DeletedNotes.isOwnSignedRequest(request(), owner) { verified++; false })
        assertEquals("the signature is checked, not assumed", 1, verified)
    }

    @Test
    fun `someone else's request is dropped before verification`() {
        var verified = 0
        assertFalse(DeletedNotes.isOwnSignedRequest(request(pubkey = "d".repeat(64)), owner) { verified++; true })
        assertFalse(DeletedNotes.isOwnSignedRequest(request(kind = 1), owner) { verified++; true })
        assertFalse(DeletedNotes.isOwnSignedRequest(buildJsonObject { put("content", "") }, owner) { verified++; true })
        assertEquals(0, verified)
    }

    @Test
    fun `the deleted post and reposts of it are hidden, nothing else is`() {
        val deleted = setOf(gone)
        assertTrue(DeletedNotes.hides(note(gone), deleted))
        assertTrue(DeletedNotes.hides(repost("3".repeat(64), of = gone), deleted))
        assertFalse(DeletedNotes.hides(note(kept), deleted))
        assertFalse(DeletedNotes.hides(repost("4".repeat(64), of = kept), deleted))
    }

    @Test
    fun `a list keeps its order without the deleted posts`() {
        val notes = listOf(note(kept), note(gone), repost("3".repeat(64), of = gone), note("5".repeat(64)))
        assertEquals(listOf(kept, "5".repeat(64)), DeletedNotes.visible(notes, setOf(gone)).map { it.id })
        assertEquals(notes, DeletedNotes.visible(notes, emptySet()))
    }

    @Test
    fun `a cache loses the deleted post under every key`() {
        val repost = repost("3".repeat(64), of = gone)
        // The deleted id as a key for another note (a reply hint): a lookup
        // by the deleted id must not find anything either.
        val cache = mapOf(gone to note("5".repeat(64)), kept to note(kept), "hint" to note(gone), repost.id to repost)
        assertEquals(setOf(kept), DeletedNotes.visible(cache, setOf(gone)).keys)
    }
}
