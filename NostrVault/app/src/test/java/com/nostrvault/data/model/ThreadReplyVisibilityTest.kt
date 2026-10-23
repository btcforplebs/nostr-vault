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
    fun `descendants reach every depth only`() {
        data class N(val id: String, val parent: String?)
        val notes = listOf(N("a", "root"), N("b", "a"), N("c", "b"), N("x", "other"), N("root", null))
        val ids = ThreadReplyVisibility.descendants("root", notes, { it.id }, { it.parent }).map { it.id }
        assertEquals(setOf("a", "b", "c"), ids.toSet())
        assertEquals(3, ids.size)
    }

    /**
     * Logen's report (iOS #1085): a thread showed only the author's own replies. Every reply shows,
     * strangers' and the newest included, and the author's answer to a stranger stays under it.
     * Only what `hidden` drops goes.
     */
    @Test
    fun `every reply shows except hidden ones`() {
        val pool = listOf(
            note("root", null, author = "op"),
            note("op-self", "root", author = "op"),
            note("stranger", "root", author = "stranger"),
            note("op-answer", "stranger", author = "op"),
            note("newest", "root", author = "newcomer"),
            note("blocked", "root", author = "blocked"),
            note("elsewhere", "other", author = "stranger"),
        )
        val ids = ThreadReplyVisibility.shown("root", pool) { it.pubkey == "blocked" }.map { it.id }
        assertEquals(setOf("op-self", "stranger", "op-answer", "newest"), ids.toSet())
    }

    /** The thread view uses it, with no "from outside your network" fold left (source-level). */
    @Test
    fun `the thread view folds nothing`() {
        val screen = java.io.File("src/main/java/com/nostrvault/ui/screens/notedetail/NoteDetailScreen.kt").readText()
        assertTrue(screen.contains("ThreadReplyVisibility.shown("))
        assertFalse(screen.contains("outside your network"))
    }
}
