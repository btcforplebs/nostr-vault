package com.nostrvault.ui.screens.feed

import com.nostrvault.data.model.FeedNote
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.Date

@OptIn(ExperimentalCoroutinesApi::class)
class FeedAncestorBatchTest {
    private fun note(id: String, parent: String? = null, root: String? = null) = FeedNote(
        id = id, pubkey = "a", content = "", createdAt = Date(0),
        tags = buildList {
            if (root != null) add(listOf("e", root, "", "root"))
            if (parent != null && parent != root) add(listOf("e", parent, "", "reply"))
        },
        kind = 1, repostedBy = null, isReply = parent != null, replyToPubkey = null, parentEventId = parent,
        mediaURLs = emptyList(), linkURLs = emptyList(), quotedEventIds = emptyList(), repostedEventId = null,
    )

    /** The same set the old inline code made: parents and roots the cache holds. */
    @Test
    fun `resolved gaps match the old intersect`() {
        val notes = listOf(note("a"), note("b", parent = "p1", root = "r1"), note("c", parent = "p2"))
        val cache = mapOf("p1" to 1, "r1" to 2, "zz" to 3, "a" to 4)
        val old = cache.keys.intersect(buildSet { notes.forEach { n -> n.parentEventId?.let { add(it) }; add(n.threadRootId) } })
        assertEquals(old, FeedAncestorBatch.resolved(FeedAncestorBatch.gaps(notes), cache))
        assertEquals(emptySet<String>(), FeedAncestorBatch.resolved(setOf("p1"), emptyMap<String, Int>()))
    }

    @Test
    fun `a burst lands as one value per window and the last one is kept`() = runTest {
        val source = MutableSharedFlow<Int>()
        val got = mutableListOf<Int>()
        val job = launch { source.batched(150).toList(got) }
        runCurrent()
        source.emit(1); runCurrent()          // the first goes out at once
        source.emit(2); source.emit(3); source.emit(4); runCurrent()
        assertEquals(listOf(1), got)
        advanceTimeBy(151); runCurrent()       // the window ends: only the newest
        assertEquals(listOf(1, 4), got)
        advanceTimeBy(500); runCurrent()
        assertEquals(listOf(1, 4), got)
        job.cancel()
    }

    @Test
    fun `a NIP-22 comment fetches its E root with its parent`() {
        val comment = FeedNote(
            id = "c", pubkey = "a", content = "", createdAt = Date(0),
            tags = listOf(
                listOf("E", "root", "wss://relay.ditto.pub", "b"), listOf("K", "1"),
                listOf("e", "parent", "wss://127.0.0.1:3355", "d"), listOf("k", "1111"),
            ),
            kind = 1111, repostedBy = null, isReply = true, replyToPubkey = null, parentEventId = "parent",
            mediaURLs = emptyList(), linkURLs = emptyList(), quotedEventIds = emptyList(), repostedEventId = null,
        )
        assertEquals(listOf("parent", "root"), FeedAncestorBatch.rowFetchIds(comment))
        // A kind 1 reply still asks for its parent only, as before.
        assertEquals(listOf("p1"), FeedAncestorBatch.rowFetchIds(note("b", parent = "p1", root = "r1")))
    }
}
