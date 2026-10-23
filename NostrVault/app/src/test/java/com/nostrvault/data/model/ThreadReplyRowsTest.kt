package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Date

class ThreadReplyRowsTest {

    private fun note(id: String, seconds: Long, parent: String?): FeedNote = FeedNote(
        id = id,
        pubkey = "alice",
        content = "",
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

    /** The recursive ThreadedReplyNode this replaces, as a reference walk. */
    private fun recursive(targetId: String, pool: List<FeedNote>): List<Pair<String, Int>> {
        val out = mutableListOf<Pair<String, Int>>()
        fun node(reply: FeedNote, depth: Int) {
            out.add(reply.id to depth)
            val kids = pool.filter { it.parentEventId == reply.id }
            if (kids.isNotEmpty() && depth < ThreadReplyRows.COLLAPSE_DEPTH) kids.forEach { node(it, depth + 1) }
        }
        pool.filter { it.parentEventId == targetId }.sortedBy { it.createdAt }.forEach { node(it, 1) }
        return out
    }

    @Test
    fun `direct replies oldest first, each followed by its own replies in pool order`() {
        val pool = listOf(
            note("b", 20, "root"),
            note("a", 10, "root"),
            note("a2", 15, "a"),
            note("a1", 12, "a"),
            note("a1x", 13, "a1"),
        )
        val rows = ThreadReplyRows.build("root", pool)
        assertEquals(listOf("a", "a2", "a1", "a1x", "b"), rows.map { it.id })
        assertEquals(listOf(1, 2, 2, 3, 1), rows.map { it.depth })
        assertEquals(listOf(2, 2, 3, 1, 0), rows.map { it.nextDepth })
        assertEquals(listOf(true, true, false, true, false), rows.map { it.isFirstChild })
    }

    @Test
    fun `replies at the collapse depth show a pill instead of their own replies`() {
        val pool = listOf(
            note("a", 1, "root"),
            note("b", 2, "a"),
            note("c", 3, "b"),
            note("d1", 4, "c"),
            note("d2", 5, "c"),
            note("e", 6, "d1"),
        )
        val rows = ThreadReplyRows.build("root", pool)
        assertEquals(listOf("a", "b", "c"), rows.map { it.id })
        assertEquals(listOf(0, 0, 2), rows.map { it.collapsedReplies })
    }

    @Test
    fun `same rows as the recursive tree on a 150-reply thread`() {
        val rng = java.util.Random(7)
        val pool = mutableListOf<FeedNote>()
        for (i in 0 until 150) {
            val parent = if (i < 20 || rng.nextInt(3) == 0) "root" else pool[rng.nextInt(pool.size)].id
            pool.add(note("n$i", rng.nextInt(10_000).toLong(), parent))
        }
        val rows = ThreadReplyRows.build("root", pool)
        assertEquals(recursive("root", pool), rows.map { it.id to it.depth })
    }

    @Test
    fun `a reply loop does not repeat rows`() {
        val pool = listOf(note("a", 1, "root"), note("b", 2, "a"), note("a", 3, "b"))
        val rows = ThreadReplyRows.build("root", pool)
        assertEquals(rows.map { it.id }.distinct(), rows.map { it.id })
        assertTrue(rows.isNotEmpty())
    }

    @Test
    fun `reply counts count direct replies only`() {
        val pool = listOf(note("a", 1, "root"), note("b", 2, "a"), note("c", 3, "a"), note("d", 4, "b"))
        assertEquals(mapOf("root" to 1, "a" to 2, "b" to 1), ThreadReplyRows.replyCounts(pool))
    }
}
