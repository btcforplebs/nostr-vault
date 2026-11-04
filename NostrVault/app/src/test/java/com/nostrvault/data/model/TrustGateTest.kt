package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Date

/** The one web-of-trust rule for replies, comments, chat and sheets (Logen 2026-11-04). */
class TrustGateTest {
    private val me = "me"
    private val author = "author"
    private val friend = "friend"
    private val stranger = "stranger"
    private val always = setOf(me, author)
    private val web = setOf(friend)

    private fun note(id: String, pubkey: String, parent: String?): FeedNote = FeedNote(
        id = id,
        pubkey = pubkey,
        content = "",
        createdAt = Date(0),
        tags = if (parent != null) listOf(listOf("e", parent, "", "root")) else emptyList(),
        kind = 1,
        repostedBy = null,
        isReply = parent != null,
        replyToPubkey = null,
        parentEventId = parent,
        mediaURLs = emptyList(),
        linkURLs = emptyList(),
        quotedEventIds = emptyList(),
        repostedEventId = null,
    )

    @Test
    fun webMeAndAuthorPassStrangerDoesNot() {
        assertTrue(TrustGate.allows(friend, web, always))
        assertTrue(TrustGate.allows(me, web, always))
        assertTrue(TrustGate.allows(author, web, always))
        assertFalse(TrustGate.allows(stranger, web, always))
    }

    @Test
    fun emptyWebFailsClosed() {
        assertFalse(TrustGate.allows(friend, emptySet(), always))
        assertFalse(TrustGate.allows(stranger, emptySet(), always))
        assertTrue(TrustGate.allows(me, emptySet(), always))
        assertTrue(TrustGate.allows(author, emptySet(), always))
    }

    @Test
    fun everyoneShieldLetsAllThrough() {
        assertTrue(TrustGate.allows(stranger, null, always))
        val (inside, outside) = TrustGate.split(listOf(stranger, friend), null, always) { it }
        assertEquals(listOf(stranger, friend), inside)
        assertTrue(outside.isEmpty())
    }

    @Test
    fun splitKeepsOrder() {
        val (inside, outside) = TrustGate.split(listOf(stranger, friend, me, "other"), web, always) { it }
        assertEquals(listOf(friend, me), inside)
        assertEquals(listOf(stranger, "other"), outside)
    }

    /** A stranger's reply folds with everything under it, so no answer shows without what it answers. */
    @Test
    fun threadFoldTakesTheSubtree() {
        val replies = listOf(
            note("a", friend, "root"),
            note("b", stranger, "root"),
            note("c", author, "b"),
            note("d", friend, "c"),
            note("e", me, "a"),
        )
        val (inside, outside) = TrustGate.splitThread(replies, web, always)
        assertEquals(listOf("a", "e"), inside.map { it.id })
        assertEquals(listOf("b", "c", "d"), outside.map { it.id })
    }

    @Test
    fun threadFoldSurvivesACycle() {
        val replies = listOf(note("x", friend, "y"), note("y", friend, "x"))
        val (inside, outside) = TrustGate.splitThread(replies, web, always)
        assertEquals(2, inside.size)
        assertTrue(outside.isEmpty())
    }

    @Test
    fun repostNeedsBothAuthors() {
        assertTrue(TrustGate.allowsRepost(friend, friend, web, always))
        assertFalse(TrustGate.allowsRepost(friend, stranger, web, always))
        assertFalse(TrustGate.allowsRepost(stranger, friend, web, always))
    }

    @Test
    fun foldLabel() {
        assertEquals("1 reply from outside your web", TrustGate.foldLabel(1))
        assertEquals("3 replies from outside your web", TrustGate.foldLabel(3))
        assertEquals("2 messages from outside your web", TrustGate.foldLabel(2, "message", "messages"))
    }
}
