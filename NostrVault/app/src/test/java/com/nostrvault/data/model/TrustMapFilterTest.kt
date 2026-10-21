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
        )
        assertEquals(setOf("a", "b", "c"), TrustMap.lit(setOf(TrustMap.Filter.TALK), matches))
        assertEquals(setOf("b", "c"), TrustMap.lit(setOf(TrustMap.Filter.TALK, TrustMap.Filter.FOLLOWS_BACK), matches))
        assertEquals(emptySet<String>(), TrustMap.lit(setOf(TrustMap.Filter.FOLLOWS_BACK), emptyMap()))
    }

    @Test
    fun filterCountsReadAsSentences() {
        assertEquals("214 talk with you", TrustMap.Filter.TALK.count(214))
        assertEquals("1 follows you back", TrustMap.Filter.FOLLOWS_BACK.count(1))
    }
}
