package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The "why?" sheet: score, ring, and who you follow follows them, highest first. No mute rows (Q3 open). */
class TrustWhyTest {
    private fun pk(c: Char) = c.toString().repeat(64)
    private val me = pk('a'); private val them = pk('t')
    private val hi = pk('1'); private val mid = pk('2'); private val unknown = pk('3')

    private fun copy(vararg people: Pair<String, TrustRankCopy.Person>) = TrustRankCopy(
        account = me, builtAt = 1_795_300_000, maxHop = 4, viewBar = 55.0, floor = 45.0, people = mapOf(*people),
    )

    private val ranked = copy(them to TrustRankCopy.Person(61.4, 2), hi to TrustRankCopy.Person(99.0, 1), mid to TrustRankCopy.Person(80.0, 1))
    private fun bridged(all: List<String>, exact: Boolean = true) = TrustPath(TrustPath.Reach.BRIDGED, all.take(5), all.size > 5, all, exact)

    @Test fun `score, ring, and followers highest score first, unscored last`() {
        val why = TrustWhy.of(them, me, ranked, bridged(listOf(unknown, mid, hi)))!!
        assertEquals(61, why.score)
        assertEquals(2, why.hop)
        assertEquals(55, why.bar)
        assertTrue(why.overBar)
        assertEquals(listOf(hi to 99, mid to 80, unknown to null), why.followers.map { it.pubkey to it.score })
        assertEquals("Score 61 of 100", TrustWhyText.headline(why))
        assertEquals("2 hops from you · at or over the 55 discovery starts at", TrustWhyText.place(why))
        assertEquals("3 people you follow follow them", TrustWhyText.followersTitle(why))
    }

    @Test fun `a relay count is a floor`() {
        val why = TrustWhy.of(them, me, ranked, bridged(listOf(hi, mid), exact = false))!!
        assertEquals("At least 2 people you follow follow them", TrustWhyText.followersTitle(why))
    }

    @Test fun `far out, under the bar, no one you follow follows them`() {
        val far = copy(them to TrustRankCopy.Person(47.2, 4))
        val why = TrustWhy.of(them, me, far, TrustPath(TrustPath.Reach.OUTSIDE, emptyList(), false))!!
        assertEquals(4, why.hop)
        assertEquals("4 hops from you · under the 55 discovery starts at", TrustWhyText.place(why))
        assertEquals("No one you follow follows them", TrustWhyText.followersTitle(why))
    }

    @Test fun `long lists are cut and counted`() {
        val many = (100 until 100 + TrustWhy.SHOWN + 3).map { "%064x".format(it) }
        val why = TrustWhy.of(them, me, ranked, bridged(many))!!
        assertEquals("and 3 more", TrustWhyText.more(why))
        assertNull(TrustWhyText.more(TrustWhy.of(them, me, ranked, bridged(listOf(hi)))!!))
    }

    @Test fun `no sheet without a score, for you, or when the web says they are outside the file's near ring`() {
        assertNull(TrustWhy.of(them, me, null, bridged(listOf(hi))))
        assertNull(TrustWhy.of(pk('z'), me, ranked, null))
        assertNull(TrustWhy.of(me, me, copy(me to TrustRankCopy.Person(99.0, 1)), null))
        // The file says ring 2, the path (live) says outside: no claim.
        assertNull(TrustWhy.of(them, me, ranked, TrustPath(TrustPath.Reach.OUTSIDE, emptyList(), false)))
    }

    @Test fun `the sheet has no mute words`() {
        val why = TrustWhy.of(them, me, ranked, bridged(listOf(hi)))!!
        val words = listOf(TrustWhyText.headline(why), TrustWhyText.place(why), TrustWhyText.followersTitle(why), TrustWhyText.HOW)
        assertTrue(words.none { it.contains("mute", ignoreCase = true) })
    }
}
