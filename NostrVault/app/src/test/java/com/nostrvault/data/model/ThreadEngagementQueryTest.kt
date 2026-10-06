package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Thread Stats asks for each batch of notes with its own limit (iOS #325). */
class ThreadEngagementQueryTest {
    private fun ids(n: Int) = (0 until n).map { "note%02d".format(it) }

    @Test
    fun splitsIntoBatchesOfTen() {
        val requests = ThreadEngagementQuery.requests(ids(27), "thr")
        assertEquals(listOf(10, 10, 7), requests.map { it.noteIds.size })
        assertEquals(listOf("thr-0", "thr-1", "thr-2"), requests.map { it.subscriptionId })
        assertEquals(ids(27).toSet(), requests.flatMap { it.noteIds }.toSet())
    }

    @Test
    fun sameThreadAlwaysSplitsTheSameWay() {
        val a = ThreadEngagementQuery.requests(ids(23).shuffled(), "x")
        val b = ThreadEngagementQuery.requests(ids(23).reversed(), "x")
        assertEquals(a, b)
        assertEquals(ids(10), a.first().noteIds)
    }

    @Test
    fun duplicatesAndEmptyThreads() {
        assertEquals(listOf("a", "b"), ThreadEngagementQuery.requests(listOf("b", "a", "a"), "x").single().noteIds)
        assertTrue(ThreadEngagementQuery.requests(emptyList(), "x").isEmpty())
    }

    @Test
    fun eachBatchCarriesItsOwnLimit() {
        val request = ThreadEngagementQuery.requests(listOf("b", "a"), "x").single()
        assertEquals("""{"kinds":[6,7,9735],"#e":["a","b"],"limit":500}""", request.filter)
    }

    @Test
    fun timeoutGrowsWithBatchesUpToTwentySeconds() {
        assertEquals(6_000L, ThreadEngagementQuery.timeoutMs(1))
        assertEquals(10_000L, ThreadEngagementQuery.timeoutMs(3))
        assertEquals(20_000L, ThreadEngagementQuery.timeoutMs(40))
    }

    @Test
    fun engagementCountsForTheLastThreadNoteItTags() {
        val thread = setOf("root", "reply")
        val tags = listOf(listOf("e", "root"), listOf("e", "reply"), listOf("p", "x"))
        assertEquals("reply", ThreadEngagementQuery.targetNoteId(tags, thread))
        assertEquals("root", ThreadEngagementQuery.targetNoteId(listOf(listOf("e", "root"), listOf("e", "elsewhere")), thread))
        assertNull(ThreadEngagementQuery.targetNoteId(listOf(listOf("e", "elsewhere")), thread))
    }
}
