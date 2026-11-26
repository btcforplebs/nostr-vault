package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** A hop sphere person's path in to you (Logen 2026-11-25). iOS `GlobeChainTests.swift`. */
class GlobeChainTest {
    private fun pk(i: Int) = "%064x".format(i)
    private val me = pk(0xa)

    /** Follow 1; hop 2: 2 (via 1); hop 3: 3 (via 2); hop 4: 4 (via 3), 5 (via 6, unknown). */
    private fun copy(): TrustRankCopy {
        val globe = listOf(
            "[\"${pk(2)}\",60,2,\"${pk(1)}\"]", "[\"${pk(3)}\",50,3,\"${pk(2)}\"]",
            "[\"${pk(4)}\",40,4,\"${pk(3)}\"]", "[\"${pk(5)}\",30,4,\"${pk(6)}\"]",
        ).joinToString(",")
        val text = "{\"account\":\"$me\",\"builtAt\":1795300000,\"version\":2,\"maxHop\":5," +
            "\"people\":[[\"${pk(1)}\",100,1]],\"globe\":[$globe],\"viewBar\":55,\"floor\":0}"
        return TrustRankCopy.parse(text, me)!!
    }

    @Test fun `hop 4 walks in through every ring to a follow`() {
        val links = GlobeChain.links(pk(4), copy(), setOf(pk(1)))
        assertEquals(listOf(pk(4), pk(3), pk(2), pk(1)), links.map { it.key })
        assertEquals(listOf(4, 3, 2, 1), links.map { it.hop })
    }

    @Test fun `an unknown link ends the walk there`() {
        val links = GlobeChain.links(pk(5), copy(), setOf(pk(1)))
        assertEquals(listOf(pk(5), pk(6)), links.map { it.key })
        assertNull(links.last().hop)
    }

    @Test fun `no copy or not on the globe is no path`() {
        assertEquals(emptyList<GlobeChain.Link>(), GlobeChain.links(pk(4), null, emptySet()))
        assertEquals(emptyList<GlobeChain.Link>(), GlobeChain.links(pk(99), copy(), emptySet()))
    }

    @Test fun `a path skips links off screen and rings the start only when it is the tapped person`() {
        val (points, starts) = GlobeChain.path(listOf("a", null, "c"))
        assertEquals(listOf("a", "c"), points)
        assertTrue(starts)
        val (rest, ringed) = GlobeChain.path(listOf(null, "b", "c"))
        assertEquals(listOf("b", "c"), rest)
        assertFalse(ringed)
    }
}
