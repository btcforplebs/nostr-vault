package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Test

/** A hop sphere person's path in to you (Logen 2026-11-25). iOS twin: `MediaLogicTests/GlobeChainTests.swift`. */
class GlobeChainTest {
    private fun pk(i: Int) = "%064x".format(i)
    private val me = pk(0xa)

    /** 4 via 3 via 2 via follow 9; 5 via 6 via 5 loops. */
    private fun copy(): TrustRankCopy? {
        val globe = listOf(
            Triple(4, 4, 3), Triple(3, 3, 2), Triple(2, 2, 9), Triple(5, 3, 6), Triple(6, 2, 5),
        ).joinToString(",") { (k, hop, via) -> "[\"${pk(k)}\",50,$hop,\"${pk(via)}\"]" }
        val text = "{\"account\":\"$me\",\"builtAt\":1795300000,\"version\":2,\"maxHop\":6," +
            "\"people\":[[\"${pk(9)}\",100,1]],\"globe\":[$globe],\"viewBar\":55,\"floor\":45}"
        return TrustRankCopy.parse(text, me)
    }

    @Test fun `the path runs in through each via to one of your follows`() {
        val links = GlobeChain.links(pk(4), copy(), setOf(pk(9)))
        assertEquals(
            listOf(GlobeChain.Link(pk(4), 4), GlobeChain.Link(pk(3), 3), GlobeChain.Link(pk(2), 2), GlobeChain.Link(pk(9), 1)),
            links,
        )
    }

    @Test fun `it never loops and stops where the copy stops knowing`() {
        assertEquals(listOf(GlobeChain.Link(pk(5), 3), GlobeChain.Link(pk(6), 2)), GlobeChain.links(pk(5), copy(), emptySet()))
        assertEquals(listOf(GlobeChain.Link(pk(2), 2), GlobeChain.Link(pk(9), null)), GlobeChain.links(pk(2), copy(), emptySet()))
        assertEquals(emptyList<GlobeChain.Link>(), GlobeChain.links(pk(77), copy(), emptySet()))
        assertEquals(emptyList<GlobeChain.Link>(), GlobeChain.links(pk(4), null, emptySet()))
    }
}
