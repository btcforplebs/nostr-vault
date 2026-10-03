package com.nostrvault.ui.screens.feed

import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedThread
import com.nostrvault.data.model.FeedThreadGrouping
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Date

/** Keeping your place across expanded / condensed / threaded (iOS PR #130). */
class FeedLayoutAnchorTest {

    private fun note(id: String, seconds: Long, parent: String? = null, root: String? = null): FeedNote {
        val tags = buildList {
            if (root != null) add(listOf("e", root, "", "root"))
            if (parent != null && parent != root) add(listOf("e", parent, "", "reply"))
        }
        return FeedNote(
            id = id,
            pubkey = "alice",
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

    // Flat feed, newest first. Thread R: r (root) <- r1 <- r2. Thread S: s alone.
    // Thread T: only replies t1, t2 to a root the feed never loaded.
    private val flat = listOf(
        note("r2", 900, parent = "r1", root = "r"),
        note("s", 800),
        note("t2", 700, parent = "t", root = "t"),
        note("r1", 600, parent = "r", root = "r"),
        note("r", 500),
        note("t1", 400, parent = "t", root = "t"),
        note("u", 300),
    )
    private val flatIds = flat.map { it.id }
    private val threads: List<FeedThread> = FeedThreadGrouping.build(flat)

    private fun threadIndex(rootId: String) = threads.indexOfFirst { it.rootId == rootId }

    @Test fun `flat to flat keeps the same note`() {
        assertEquals(3, FeedLayoutAnchor.note("r1").indexInNotes(flatIds))
    }

    @Test fun `flat to threaded lands on the card holding the note`() {
        assertEquals(threadIndex("r"), FeedLayoutAnchor.note("r1").indexInThreads(threads))
        assertEquals(threadIndex("r"), FeedLayoutAnchor.note("r").indexInThreads(threads))
        assertEquals(threadIndex("s"), FeedLayoutAnchor.note("s").indexInThreads(threads))
        // A reply whose root never loaded still finds its card.
        assertEquals(threadIndex("t"), FeedLayoutAnchor.note("t1").indexInThreads(threads))
    }

    @Test fun `threaded to flat lands on the card's first note in reading order`() {
        val r = threads[threadIndex("r")]
        // Root first: "r" sits at flat index 4.
        assertEquals(4, FeedLayoutAnchor.thread(r).indexInNotes(flatIds))
        // Rootless thread: its first loaded reply in reading order, t1.
        val t = threads[threadIndex("t")]
        assertEquals(5, FeedLayoutAnchor.thread(t).indexInNotes(flatIds))
    }

    @Test fun `threaded to flat falls back to a reply when the root is filtered out`() {
        val r = threads[threadIndex("r")]
        val withoutRoot = flatIds - "r"
        assertEquals(withoutRoot.indexOf("r1"), FeedLayoutAnchor.thread(r).indexInNotes(withoutRoot))
    }

    @Test fun `round trip through every layout returns to the same row`() {
        for ((i, id) in flatIds.withIndex()) {
            val card = FeedLayoutAnchor.note(id).indexInThreads(threads)!!
            val back = FeedLayoutAnchor.thread(threads[card]).indexInNotes(flatIds)!!
            // Back on a note of the same thread.
            val thread = threads[card]
            val backId = flatIds[back]
            assertTrue("row $i", thread.rootId == backId || thread.entries.any { it.note.id == backId })
        }
    }

    @Test fun `a note that left the feed has no row`() {
        assertNull(FeedLayoutAnchor.note("gone").indexInNotes(flatIds))
        assertNull(FeedLayoutAnchor.note("gone").indexInThreads(threads))
        assertNull(FeedLayoutAnchor.note("r").indexInThreads(emptyList()))
    }

    @Test fun `top row skips one mostly hidden under the toolbar`() {
        // (index, offset, size): row 3 shows 20 of 200 px, row 4 is fully in view.
        assertEquals(4, FeedLayoutAnchor.topRowIndex(listOf(Triple(3, -180, 200), Triple(4, 20, 300))))
        // Row 3 shows 60 of 200 px (30%): it still counts.
        assertEquals(3, FeedLayoutAnchor.topRowIndex(listOf(Triple(3, -140, 200), Triple(4, 60, 300))))
        assertEquals(0, FeedLayoutAnchor.topRowIndex(listOf(Triple(0, 0, 100))))
        assertNull(FeedLayoutAnchor.topRowIndex(emptyList()))
    }
}
