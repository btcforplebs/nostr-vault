package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The discovery feed's author set is this ranking truncated to 500, so the
 * order has to be total: an arbitrary tie-break means a different feed every
 * time the same data is recomputed. Mirrors iOS ExtendedNetworkRankingTests.
 */
class ExtendedNetworkRankingTest {

    @Test
    fun `ranks by mutual follow count descending`() {
        assertEquals(
            listOf("b", "c", "a"),
            ContactManager.rankExtendedNetwork(mapOf("a" to 1, "b" to 5, "c" to 3)),
        )
    }

    /** Most of the second hop ties at one or two mutuals. */
    @Test
    fun `ties break on pubkey so the order is total`() {
        assertEquals(
            listOf("aaa", "bbb", "ccc"),
            ContactManager.rankExtendedNetwork(mapOf("ccc" to 2, "aaa" to 2, "bbb" to 2)),
        )
    }

    /** The cut lands inside the tie group, so the tie-break decides who survives. */
    @Test
    fun `the cut line inside a tie group is decided by the tie break`() {
        val counts = (0 until 100).associate { String.format("pk%03d", it) to 1 }
        assertEquals(
            (0 until 10).map { String.format("pk%03d", it) },
            ContactManager.rankExtendedNetwork(counts, maxResults = 10),
        )
    }

    @Test
    fun `empty counts rank to nothing`() {
        assertTrue(ContactManager.rankExtendedNetwork(emptyMap()).isEmpty())
    }

    @Test
    fun `counts one per p tag and excludes your own follows`() {
        val tags = listOf(listOf("p", "alice"), listOf("p", "bob"), listOf("e", "note"), listOf("p"))
        assertEquals(
            mapOf("alice" to 1),
            ContactManager.countMutualFollows(tags, setOf("bob")),
        )
    }
}
