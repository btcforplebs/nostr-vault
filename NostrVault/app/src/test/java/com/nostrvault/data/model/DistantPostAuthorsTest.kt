package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Discovery design B: who Discover asks the local feed store for. iOS `DistantPostAuthorsTests.swift`. */
class DistantPostAuthorsTest {
    private fun pk(c: Char) = c.toString().repeat(64)
    private val me = pk('a')

    private fun copy(rows: String): TrustRankCopy =
        TrustRankCopy.parse(
            "{\"account\":\"$me\",\"builtAt\":1795300000,\"version\":2,\"maxHop\":6," +
                "\"people\":[$rows],\"viewBar\":55,\"floor\":45}", me,
        )!!

    @Test fun `the pick is the admitted distant people highest score first`() {
        val rows = listOf(Triple('b', 100, 1), Triple('c', 90, 2), Triple('d', 60, 3), Triple('e', 80, 4), Triple('f', 70, 3), Triple('0', 70, 6))
            .joinToString(",") { "[\"${pk(it.first)}\",${it.second},${it.third}]" }
        val copy = copy(rows)
        val admitted = DiscoveryReach.admitted(copy, 55.0)
        assertEquals("score order, ties by key; hop 1-2 never", listOf(pk('e'), pk('0'), pk('f'), pk('d')), DistantPostAuthors.pick(admitted.distant, copy, emptySet()))
        assertEquals("the bar decides who is asked for", listOf(pk('e')), DistantPostAuthors.pick(DiscoveryReach.admitted(copy, 75.0).distant, copy, emptySet()))
        assertEquals(emptyList<String>(), DistantPostAuthors.pick(admitted.distant, null, emptySet()))
    }

    @Test fun `the pick stops at what the Vault fetches`() {
        val keys = (1..DistantPostAuthors.MAX + 20).map { "%064x".format(it) }
        val rows = keys.mapIndexed { i, k -> "[\"$k\",${50 + i % 40},3]" }.joinToString(",")
        val copy = copy(rows)
        val pick = DistantPostAuthors.pick(keys.toSet(), copy, emptySet())
        assertEquals(DistantPostAuthors.MAX, pick.size)
        assertEquals(89.0, copy.people[pick[0]]!!.score, 0.0)
        // Mutes go before the cut, as the engine's do: the muted top people
        // leave room for the ones the Vault fetches in their place.
        val muted = pick.take(7).toSet()
        val unmuted = DistantPostAuthors.pick(keys.toSet(), copy, muted)
        assertEquals(DistantPostAuthors.MAX, unmuted.size)
        assertEquals(emptySet<String>(), muted intersect unmuted.toSet())
        assertEquals(pick.drop(7), unmuted.take(DistantPostAuthors.MAX - 7))
    }

    @Test fun `the local filter keeps the request and swaps the authors`() {
        val base = "{\"kinds\":[1,6],\"authors\":[\"${pk('c')}\",\"${pk('d')}\"],\"since\":10,\"limit\":500}"
        assertNull(DistantPostAuthors.localFilter(base, emptyList()))
        assertNull("no authors to swap", DistantPostAuthors.localFilter("{\"kinds\":[1],\"limit\":5}", listOf(pk('e'))))
        assertEquals(
            "{\"kinds\":[1,6],\"authors\":[\"${pk('e')}\"],\"since\":10,\"limit\":500}",
            DistantPostAuthors.localFilter(base, listOf(pk('e'))),
        )
    }
}
