package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Date

/** Mirrors iOS `ThreadReplyVisibilityTests` (ThreadSpecTests.swift). */
class ThreadReplyVisibilityTest {

    private fun note(id: String, parent: String?, author: String = "friend", seconds: Long = 0) = FeedNote(
        id = id,
        pubkey = author,
        content = "hi",
        createdAt = Date(seconds * 1000),
        tags = emptyList(),
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
    fun `outside needs a loaded graph`() {
        assertFalse(ThreadReplyVisibility.isOutside("stranger", trusted = emptySet(), insiders = emptySet()))
        assertTrue(ThreadReplyVisibility.isOutside("stranger", trusted = setOf("friend"), insiders = emptySet()))
        assertFalse(ThreadReplyVisibility.isOutside("friend", trusted = setOf("friend"), insiders = emptySet()))
        // The opened note's author is never folded, trusted or not.
        assertFalse(ThreadReplyVisibility.isOutside("op", trusted = setOf("friend"), insiders = setOf("op")))
    }

    @Test
    fun `descendants reach every depth only`() {
        data class N(val id: String, val parent: String?)
        val notes = listOf(N("a", "root"), N("b", "a"), N("c", "b"), N("x", "other"), N("root", null))
        val ids = ThreadReplyVisibility.descendants("root", notes, { it.id }, { it.parent }).map { it.id }
        assertEquals(setOf("a", "b", "c"), ids.toSet())
        assertEquals(3, ids.size)
    }

    @Test
    fun `replies drop hidden ones and fold strangers until asked`() {
        val pool = listOf(
            note("focus", null, author = "op"),
            note("a", "focus", author = "friend"),
            note("spam", "focus", author = "friend"),
            note("s", "focus", author = "stranger"),
            note("op2", "s", author = "op"),
            note("elsewhere", "other", author = "friend"),
        )
        val hidden: (FeedNote) -> Boolean = { it.id == "spam" }
        val folded = ThreadReplyVisibility.replies(
            "focus", pool, hidden, trusted = setOf("friend"), insiders = setOf("op"), showOutside = false,
        )
        assertEquals(setOf("a", "op2"), folded.visible.map { it.id }.toSet())
        assertEquals(1, folded.outside)

        val shown = ThreadReplyVisibility.replies(
            "focus", pool, hidden, trusted = setOf("friend"), insiders = setOf("op"), showOutside = true,
        )
        assertEquals(setOf("a", "s", "op2"), shown.visible.map { it.id }.toSet())
        assertEquals(0, shown.outside)
    }
}
