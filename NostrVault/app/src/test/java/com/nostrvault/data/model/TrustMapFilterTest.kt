package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Port of iOS TrustMapTests' filter cases. */
class TrustMapFilterTest {

    @Test
    fun noFilterOnLightsEveryone() {
        assertNull(TrustMap.lit(emptySet(), mapOf(TrustMap.Filter.TALK to setOf("a"))))
    }

    @Test
    fun twoFiltersNarrowToWhoMatchesBoth() {
        val matches = mapOf(
            TrustMap.Filter.TALK to setOf("a", "b", "c"),
            TrustMap.Filter.FOLLOWS_BACK to setOf("b", "c", "d"),
            TrustMap.Filter.NEW to setOf("c"),
        )
        assertEquals(setOf("a", "b", "c"), TrustMap.lit(setOf(TrustMap.Filter.TALK), matches))
        assertEquals(setOf("b", "c"), TrustMap.lit(setOf(TrustMap.Filter.TALK, TrustMap.Filter.FOLLOWS_BACK), matches))
        assertEquals(setOf("c"), TrustMap.lit(TrustMap.Filter.entries.toSet(), matches))
        assertEquals(emptySet<String>(), TrustMap.lit(setOf(TrustMap.Filter.NEW), emptyMap()))
    }

    @Test
    fun newcomersAreWhoJoinedSinceYouLooked() {
        assertEquals(setOf("b", "c"), TrustMap.newcomers(setOf("a", "b", "c"), setOf("a")))
        assertEquals(emptySet<String>(), TrustMap.newcomers(setOf("a"), null))
    }

    @Test
    fun filterCountsReadAsSentences() {
        assertEquals("214 talk with you", TrustMap.Filter.TALK.count(214))
        assertEquals("1 follows you back", TrustMap.Filter.FOLLOWS_BACK.count(1))
        assertEquals("1 new in your web", TrustMap.Filter.NEW.count(1))
        assertEquals("No one new since your last look", TrustMap.Filter.NEW.count(0))
    }
}
