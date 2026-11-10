package com.nostrvault.service

import com.nostrvault.data.model.FeedNote
import org.junit.Assert.assertEquals
import org.junit.Test
import kotlin.random.Random

/** The in-order merge must give exactly what the full re-sort it replaced gave. */
class FeedNoteMergeTest {
    private fun note(id: String, at: Long) =
        FeedNote.fromEvent(id.padEnd(64, '0'), "a".repeat(64), id, emptyList(), at, 1)

    private fun fullSort(base: List<FeedNote>, incoming: List<FeedNote>, cap: Int): List<FeedNote> {
        val m = (base + incoming).distinctBy { it.id }.sortedByDescending { it.createdAt }
        return if (m.size > cap) m.take(cap) else m
    }

    private fun ids(notes: List<FeedNote>) = notes.map { it.id.trimEnd('0') }

    @Test
    fun `equal timestamps keep the feed first, then arrival order`() {
        val base = listOf(note("b1", 300), note("b2", 200), note("b3", 200), note("b4", 100))
        val incoming = listOf(note("n1", 200), note("n2", 400), note("n3", 200), note("n4", 100))
        val merged = FeedNoteMerge.mergeNewestFirst(base, incoming, 100)
        assertEquals(listOf("n2", "b1", "b2", "b3", "n1", "n3", "b4", "n4"), ids(merged))
        assertEquals(ids(fullSort(base, incoming, 100)), ids(merged))
    }

    @Test
    fun `out-of-order batch, duplicates and cap match the full sort`() {
        val base = listOf(note("b1", 500), note("b2", 300))
        val incoming = listOf(note("n1", 100), note("b2", 900), note("n2", 600), note("n1", 700), note("n3", 300))
        val merged = FeedNoteMerge.mergeNewestFirst(base, incoming, 4)
        assertEquals(listOf("n2", "b1", "b2", "n3"), ids(merged))
        assertEquals(ids(fullSort(base, incoming, 4)), ids(merged))
    }

    @Test
    fun `a base that is not newest-first is fully sorted`() {
        val base = listOf(note("b1", 100), note("b2", 300))
        val incoming = listOf(note("n1", 200))
        assertEquals(listOf("b2", "n1", "b1"), ids(FeedNoteMerge.mergeNewestFirst(base, incoming, 10)))
    }

    @Test
    fun `random batches match the full sort`() {
        val rnd = Random(1885)
        repeat(2_000) {
            val pool = (0 until 40).map { "i$it" }
            val sorted = rnd.nextBoolean()
            var base = (0 until rnd.nextInt(0, 30)).map { note(pool[rnd.nextInt(pool.size)], rnd.nextLong(0, 8)) }
                .distinctBy { it.id }
            if (sorted) base = base.sortedByDescending { it.createdAt }
            val incoming = (0 until rnd.nextInt(0, 15)).map { note(pool[rnd.nextInt(pool.size)], rnd.nextLong(0, 8)) }
            val cap = rnd.nextInt(1, 40)
            assertEquals(ids(fullSort(base, incoming, cap)), ids(FeedNoteMerge.mergeNewestFirst(base, incoming, cap)))
        }
    }
}
