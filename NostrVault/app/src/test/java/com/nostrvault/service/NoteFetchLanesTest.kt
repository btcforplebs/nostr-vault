package com.nostrvault.service

import com.nostrvault.service.NoteFetchLanes.Lane
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The quote in the row on screen is not sent behind the rest of the feed's lookups. */
class NoteFetchLanesTest {
    @Test
    fun nearScreenIdsLeaveTheRestLane() {
        val lanes = NoteFetchLanes()
        lanes.add(listOf("p1", "p2", "quote", "p3"), Lane.REST)
        lanes.add(listOf("quote"), Lane.NEAR_SCREEN)
        assertEquals(listOf("quote"), lanes.drain(Lane.NEAR_SCREEN))
        assertEquals(listOf("p1", "p2", "p3"), lanes.drain(Lane.REST))
    }

    @Test
    fun theFeedWideAskDoesNotTakeANearScreenIdBack() {
        val lanes = NoteFetchLanes()
        lanes.add(listOf("quote"), Lane.NEAR_SCREEN)
        lanes.add(listOf("p1", "quote"), Lane.REST)
        assertEquals(listOf("p1"), lanes.drain(Lane.REST))
        assertEquals(listOf("quote"), lanes.drain(Lane.NEAR_SCREEN))
    }

    @Test
    fun drainEmptiesTheLaneAndKeepsOrder() {
        val lanes = NoteFetchLanes()
        lanes.add(listOf("b", "a", "b"), Lane.NEAR_SCREEN)
        assertEquals(listOf("b", "a"), lanes.drain(Lane.NEAR_SCREEN))
        assertTrue(lanes.drain(Lane.NEAR_SCREEN).isEmpty())
    }

    @Test
    fun nearScreenWaitsLessThanTheRest() {
        assertTrue(Lane.NEAR_SCREEN.delayMs < Lane.REST.delayMs)
    }

    // ── ReferencedNoteCache ──

    @Test
    fun anOldQuotedNoteSurvivesTheTrim() {
        // 600 fetched notes the feed still points at; the quote is the oldest.
        val cache = (0 until 600).associate { "id$it" to it.toLong() }
        val referenced = cache.keys
        val trimmed = ReferencedNoteCache.trimmed(cache, referenced, keep = "id599")
        assertEquals(600, trimmed.size)
        assertTrue("id0" in trimmed)
    }

    @Test
    fun whatNoLoadedNotePointsAtIsDroppedButNotTheNoteJustFetched() {
        val cache = mapOf("gone" to 1, "used" to 2, "new" to 3)
        assertEquals(setOf("used", "new"), ReferencedNoteCache.trimmed(cache, setOf("used"), keep = "new").keys)
    }

    @Test
    fun theNextTrimWaitsForAnotherStep() {
        assertEquals(ReferencedNoteCache.FLOOR, ReferencedNoteCache.nextTrimAt(10))
        assertEquals(900 + ReferencedNoteCache.STEP, ReferencedNoteCache.nextTrimAt(900))
    }
}
