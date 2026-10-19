package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Someone else's globe: their web from their follows' lists, and the layer
 * picker still lighting your part of it. Port of iOS TrustMapWiderWebTests.
 */
class TrustMapWiderTest {
    private fun key(n: Int) = String.format("%064x", n)
    private val center = String.format("%064x", 9_999)

    private fun list(signer: String, follows: List<String>, at: Long = 100, kind: Int = 3) =
        ContactList(signer, at, follows.map { listOf("p", it) }, kind)

    @Test
    fun widerWebCountsHowManyOfTheirFollowsNameEachPerson() {
        val (a, b, c) = Triple(key(1), key(2), key(3))
        val lists = listOf(
            list(a, listOf(key(10), key(11), center)),
            list(b, listOf(key(10), c)),
            list(c, listOf(key(10))),
        )
        val wider = TrustMapWider.web(center, listOf(a, b, c), lists)
        assertEquals(3, wider.vouches[key(10)])
        assertEquals(1, wider.vouches[key(11)])
        assertEquals("a follow named by another follow still counts", 1, wider.vouches[c])
        assertNull("the core is never in their own web", wider.vouches[center])
        assertEquals(setOf(key(10), key(11), c), wider.graph)
    }

    @Test
    fun widerWebTakesTheNewestListAndOnlyTheirFollows() {
        val a = key(1)
        val lists = listOf(
            list(a, listOf(key(20)), at = 100),
            list(a, listOf(key(21)), at = 200),
            list(key(50), listOf(key(22))),
            list(a, listOf(key(23)), at = 300, kind = 1),
        )
        assertEquals(setOf(key(21)), TrustMapWider.web(center, listOf(a), lists).graph)
    }

    @Test
    fun widerSampleIsCappedAndStable() {
        val ring = (1..500).map(::key)
        val sample = TrustMapWider.sample(ring)
        assertEquals(TrustMapWider.SAMPLE_CAP, sample.size)
        assertEquals(sample, TrustMapWider.sample(ring.reversed()))
        assertEquals(listOf(key(1)), TrustMapWider.sample(listOf(key(1))))
    }

    @Test
    fun layerLitIsAboutYou() {
        val me = key(0)
        val follows = setOf(me, key(1), key(2))
        val web = setOf(key(1), key(2), key(3), key(4))
        val vouches = mapOf(key(3) to TrustMap.CLOSE_VOUCHES, key(4) to 1)
        assertNull(TrustMapWider.layerLit(TrustMap.Layer.EVERYONE, me, follows, web, vouches))
        assertEquals(setOf(key(1), key(2)), TrustMapWider.layerLit(TrustMap.Layer.FOLLOWING, me, follows, web, vouches))
        assertEquals(setOf(key(3)), TrustMapWider.layerLit(TrustMap.Layer.CLOSE, me, follows, web, vouches))
        assertEquals(setOf(key(4)), TrustMapWider.layerLit(TrustMap.Layer.FURTHER_OUT, me, follows, web, vouches))
    }

    @Test
    fun theirGlobeLightsWhatBothTheFiltersAndYourLayerLight() {
        val layer = setOf(key(1), key(2))
        assertNull(TrustMapWider.globeLit(null, null))
        assertEquals(setOf(key(5)), TrustMapWider.globeLit(setOf(key(5)), null))
        assertEquals(layer, TrustMapWider.globeLit(null, layer))
        assertEquals(setOf(key(2)), TrustMapWider.globeLit(setOf(key(2), key(3)), layer))
    }

    @Test
    fun theirHazeLeavesOutTheInnerShellsAndJudgesCloseByVouches() {
        val graph = (10..40).map(::key).toSet()
        val inner = setOf(key(10), key(11))
        val vouches = graph.associateWith { if (it == key(20)) TrustMap.CLOSE_VOUCHES else 1 }
        val layout = TrustMapWider.hazeLayout(graph, inner, vouches, center, setOf(key(10), key(11)), 1.8)
        assertTrue(layout.shell.none { it in inner })
        assertEquals(graph.size - inner.size, layout.shell.size)
        assertEquals(setOf(key(20)), layout.close)
        assertTrue(layout.layerFaces[TrustMap.Layer.EVERYONE].orEmpty().isNotEmpty())
        assertTrue(layout.layerFaces[TrustMap.Layer.EVERYONE].orEmpty().none { it in inner })
    }
}
