package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Date

/** Mirrors iOS `FeedThreadGroupingTests.swift`. */
class FeedThreadGroupingTest {

    /** Builds a minimal [FeedNote] fixture, mirroring the Swift `TestNote` helper. */
    private fun note(
        id: String,
        seconds: Long,
        parent: String? = null,
        root: String? = null,
        author: String = "alice",
    ): FeedNote {
        val tags = buildList {
            if (root != null) add(listOf("e", root, "", "root"))
            if (parent != null && parent != root) add(listOf("e", parent, "", "reply"))
        }
        return FeedNote(
            id = id,
            pubkey = author,
            content = "",
            createdAt = Date(seconds * 1000),
            tags = tags,
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
    }

    private fun ids(thread: FeedThread): List<String> = thread.entries.map { it.id }
    private fun depths(thread: FeedThread): List<Int> = thread.entries.map { it.depth }

    @Test
    fun `standalone notes each become their own thread`() {
        val notes = listOf(note("b", 200), note("a", 100))
        val threads = FeedThreadGrouping.build(notes)

        assertEquals(listOf("b", "a"), threads.map { it.rootId })
        assertEquals(listOf(1, 1), threads.map { it.entries.size })
        assertTrue(threads.all { it.replies.isEmpty() })
    }

    @Test
    fun `replies collapse into the root thread in reading order`() {
        val notes = listOf(
            note("r3", 400, parent = "root", root = "root", author = "carol"),
            note("r2", 300, parent = "r1", root = "root", author = "bob"),
            note("r1", 200, parent = "root", root = "root", author = "bob"),
            note("root", 100),
        )

        val threads = FeedThreadGrouping.build(notes)

        assertEquals(1, threads.size)
        val thread = threads[0]
        assertEquals("root", thread.rootId)
        assertEquals("root", thread.root?.id)
        assertEquals(listOf("root", "r1", "r2", "r3"), ids(thread))
        assertEquals(listOf(0, 1, 2, 1), depths(thread))
        assertEquals(listOf("r1", "r2", "r3"), thread.replies.map { it.id })
    }

    @Test
    fun `threads sort by latest activity not root age`() {
        val notes = listOf(
            note("fresh", 500),
            note("reply", 900, parent = "old", root = "old", author = "bob"),
            note("old", 100),
        )

        val threads = FeedThreadGrouping.build(notes)

        assertEquals(listOf("old", "fresh"), threads.map { it.rootId })
        assertEquals(Date(900_000), threads[0].latestActivity)
    }

    @Test
    fun `missing root is resolved through the callback`() {
        val missingRoot = note("root", 100)
        val notes = listOf(note("r1", 200, parent = "root", root = "root", author = "bob"))

        val threads = FeedThreadGrouping.build(notes) { id -> if (id == "root") missingRoot else null }

        assertEquals(1, threads.size)
        assertEquals("root", threads[0].root?.id)
        assertEquals(listOf("root", "r1"), ids(threads[0]))
        assertEquals(listOf(0, 1), depths(threads[0]))
    }

    @Test
    fun `unresolvable root still groups its replies together`() {
        val notes = listOf(
            note("r2", 300, parent = "r1", root = "ghost", author = "bob"),
            note("r1", 200, parent = "ghost", root = "ghost", author = "bob"),
        )

        val threads = FeedThreadGrouping.build(notes)

        assertEquals(1, threads.size)
        assertEquals("ghost", threads[0].rootId)
        assertNull(threads[0].root)
        assertEquals(listOf("r1", "r2"), ids(threads[0]))
        // Without a root to sit at depth 0, its replies start the indentation.
        assertEquals(listOf(1, 2), depths(threads[0]))
        assertEquals(listOf("r1", "r2"), threads[0].replies.map { it.id })
    }

    @Test
    fun `indentation stops at max depth`() {
        val notes = mutableListOf(note("n0", 0))
        for (i in 1..(FeedThreadGrouping.MAX_DEPTH + 3)) {
            notes.add(note("n$i", i.toLong(), parent = "n${i - 1}", root = "n0"))
        }

        val threads = FeedThreadGrouping.build(notes.reversed())

        assertEquals(1, threads.size)
        val observed = depths(threads[0])
        assertEquals(0, observed.first())
        assertEquals(FeedThreadGrouping.MAX_DEPTH, observed.max())
        // Every note is still present — capping indents, it never drops replies.
        assertEquals(notes.size, observed.size)
    }

    @Test
    fun `cycle does not hang`() {
        // A malformed pair that each claim the other as parent must terminate.
        val notes = listOf(
            note("a", 100, parent = "b"),
            note("b", 200, parent = "a"),
        )

        val threads = FeedThreadGrouping.build(notes)

        assertFalse(threads.isEmpty())
        val total = threads.sumOf { it.entries.size }
        assertEquals(2, total)
    }

    @Test
    fun `empty feed produces no threads`() {
        assertTrue(FeedThreadGrouping.build(emptyList()).isEmpty())
    }
}
