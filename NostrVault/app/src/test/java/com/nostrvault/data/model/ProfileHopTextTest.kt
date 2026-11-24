package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The profile's hop line: true hops at any distance, and who you follow follows them. */
class ProfileHopTextTest {
    private fun pk(c: Char) = c.toString().repeat(64)
    private val me = pk('a'); private val them = pk('t')
    private val alice = pk('1'); private val bob = pk('2'); private val carol = pk('3'); private val dan = pk('4'); private val eve = pk('5')
    private val names = mapOf(alice to "Alice", bob to "Bob", carol to "Carol", dan to "Dan", eve to "Eve")
    private fun line(path: TrustPath?, rank: TrustRankCopy.Person? = null, who: String = them) =
        ProfileHopText.line(who, me, path, rank) { names[it] ?: "?" }

    private fun bridged(all: List<String>, hasMore: Boolean = all.size > TrustPath.SHOWN_BRIDGES, exact: Boolean = true) =
        TrustPath(TrustPath.Reach.BRIDGED, all.take(TrustPath.SHOWN_BRIDGES), hasMore, all, exact)

    @Test fun `a follow is 1 hop`() {
        assertEquals("1 hop · you follow them", line(TrustPath(TrustPath.Reach.FOLLOW, emptyList(), false), TrustRankCopy.Person(99.0, 1)))
    }

    @Test fun `two hops names who you follow follows them`() {
        assertEquals("2 hops · followed by Alice", line(bridged(listOf(alice))))
        assertEquals("2 hops · followed by Alice and Bob", line(bridged(listOf(alice, bob))))
        assertEquals("2 hops · followed by Alice, Bob and 3 more", line(bridged(listOf(alice, bob, carol, dan, eve))))
        // The links file knows every bridge: an exact count past the five shown.
        val many = listOf(alice, bob) + (10..20).map { "%064x".format(it) }
        assertEquals("2 hops · followed by Alice, Bob and 11 more", line(bridged(many)))
    }

    @Test fun `relays give a floor, not a count, so no number`() {
        // Several relays can each send six lists: ten found, more may exist.
        val ten = listOf(alice, bob) + (10..17).map { "%064x".format(it) }
        assertEquals("2 hops · followed by Alice, Bob and more", line(bridged(ten, hasMore = true, exact = false)))
        assertEquals("2 hops · followed by Alice, Bob and more", line(bridged(listOf(alice, bob, carol), exact = false)))
        assertEquals("2 hops · followed by Alice and Bob", line(bridged(listOf(alice, bob), exact = false)))
        // The links file with exactly six: an exact count.
        val six = listOf(alice, bob, carol, dan, eve, pk('6'))
        assertEquals("2 hops · followed by Alice, Bob and 4 more", line(bridged(six)))
    }

    @Test fun `past two hops the Haven's ring, at any distance up to 6`() {
        for (hop in 3..6) {
            for (reach in listOf(TrustPath.Reach.WEB, TrustPath.Reach.OUTSIDE, TrustPath.Reach.UNKNOWN, null)) {
                val path = reach?.let { TrustPath(it, emptyList(), false) }
                assertEquals("$hop hops", line(path, TrustRankCopy.Person(50.0, hop)))
            }
        }
    }

    @Test fun `the near rings come from your web, never from a day-old file`() {
        // Followed since the Haven ranked: a follow, whatever the file says.
        assertEquals("1 hop · you follow them", line(TrustPath(TrustPath.Reach.FOLLOW, emptyList(), false), TrustRankCopy.Person(50.0, 3)))
        assertEquals("2 hops · followed by Alice", line(bridged(listOf(alice)), TrustRankCopy.Person(50.0, 4)))
        // Unfollowed since: the file's ring 1 is never "you follow them".
        for (reach in listOf(TrustPath.Reach.WEB, TrustPath.Reach.OUTSIDE, TrustPath.Reach.UNKNOWN, null)) {
            assertNull("$reach", line(reach?.let { TrustPath(it, emptyList(), false) }, TrustRankCopy.Person(99.0, 1)))
        }
        // Ring 2 from the file, no names, only when the path can't say; outside your web, nothing.
        assertEquals("2 hops", line(TrustPath(TrustPath.Reach.WEB, emptyList(), false), TrustRankCopy.Person(70.0, 2)))
        assertEquals("2 hops", line(null, TrustRankCopy.Person(70.0, 2)))
        assertNull(line(TrustPath(TrustPath.Reach.OUTSIDE, emptyList(), false), TrustRankCopy.Person(70.0, 2)))
    }

    @Test fun `no line for you, or for someone nobody can place`() {
        assertNull(line(null, TrustRankCopy.Person(99.0, 1), who = me))
        assertNull(line(TrustPath(TrustPath.Reach.YOU, emptyList(), false)))
        assertNull(line(null))
        assertNull(line(TrustPath(TrustPath.Reach.OUTSIDE, emptyList(), false)))
        assertNull(line(TrustPath(TrustPath.Reach.WEB, emptyList(), false)))
        assertNull(line(TrustPath(TrustPath.Reach.UNKNOWN, emptyList(), false)))
    }
}
