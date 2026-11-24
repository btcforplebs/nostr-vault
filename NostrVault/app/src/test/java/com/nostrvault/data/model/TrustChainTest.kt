package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** "You > A > B > them": the globe list's via links walked back to one of your follows. iOS `TrustChainTests.swift`. */
class TrustChainTest {
    private fun pk(c: Char) = c.toString().repeat(64)
    private val me = pk('a')
    private val a = pk('1'); private val b = pk('2'); private val c = pk('3'); private val them = pk('4')

    private fun copy(globe: List<TrustRankCopy.GlobeRow>, people: Map<String, TrustRankCopy.Person> = mapOf(a to TrustRankCopy.Person(90.0, 1))) =
        TrustRankCopy(account = me, builtAt = 1_795_300_000, maxHop = 5, viewBar = 55.0, floor = 45.0, people = people, globe = globe)

    private val full = listOf(
        TrustRankCopy.GlobeRow(b, 60.0, 2, a),
        TrustRankCopy.GlobeRow(c, 30.0, 3, b),
        TrustRankCopy.GlobeRow(them, 12.0, 4, c),
    )

    @Test fun `a hop-4 person walks back through rings 3 and 2 to your follow`() {
        val chain = TrustChain.of(them, copy(full))!!
        assertEquals(listOf(a, b, c, them), chain)
        val names = mapOf(a to "Ann", b to "Bo", c to "Cy", them to "Dee")
        assertEquals("You > Ann > Bo > Cy > Dee", TrustChain.text(chain) { names.getValue(it) })
    }

    @Test fun `a hop-3 person is You, A, B, them`() {
        assertEquals(listOf(a, b, c), TrustChain.of(c.uppercase(), copy(full)))
    }

    @Test fun `no chain when they are not in the globe list or a link is missing`() {
        assertNull("only in people", TrustChain.of(a, copy(full)))
        assertNull("ring-3 link gone", TrustChain.of(them, copy(full.filter { it.pubkey != c })))
        assertNull("ring-1 via not one of your follows", TrustChain.of(them, copy(full, people = emptyMap())))
        assertNull("ring-1 via at hop 2 in people", TrustChain.of(them, copy(full, people = mapOf(a to TrustRankCopy.Person(90.0, 2)))))
        assertNull("no copy", TrustChain.of(them, null))
    }

    @Test fun `a link that does not step one ring in is refused, so a loop can never spin`() {
        val loop = listOf(TrustRankCopy.GlobeRow(c, 30.0, 3, them), TrustRankCopy.GlobeRow(them, 12.0, 3, c))
        assertNull(TrustChain.of(them, copy(loop)))
        val skip = listOf(TrustRankCopy.GlobeRow(b, 60.0, 2, a), TrustRankCopy.GlobeRow(them, 12.0, 4, b))
        assertNull("ring 4 straight to ring 2", TrustChain.of(them, copy(skip)))
    }

    @Test fun `the why sheet carries the chain from hop 3 out, also for people only in the globe list`() {
        val why = TrustWhy.of(them, me, copy(full), TrustPath(TrustPath.Reach.OUTSIDE, emptyList(), false))!!
        assertEquals(12, why.score)
        assertEquals(4, why.hop)
        assertEquals(listOf(a, b, c, them), why.chain)
        assertEquals("You > 1 > 2 > 3 > 4", TrustWhyText.chain(why) { it.take(1) })
        val near = TrustWhy.of(b, me, copy(full), TrustPath(TrustPath.Reach.BRIDGED, listOf(a), false, listOf(a), true))!!
        assertNull("hop 2 shows who you follow, no chain line", near.chain)
    }
}
