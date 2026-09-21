package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors iOS `FeedLayoutModeTests.swift`. */
class FeedLayoutModeTest {

    @Test
    fun `cycle visits all three on a timeline`() {
        var mode = FeedLayoutMode.EXPANDED
        val seen = mutableListOf(mode)
        repeat(3) {
            mode = mode.next(supportsThreading = true)
            seen.add(mode)
        }
        assertEquals(
            listOf(FeedLayoutMode.EXPANDED, FeedLayoutMode.CONDENSED, FeedLayoutMode.THREADED, FeedLayoutMode.EXPANDED),
            seen,
        )
    }

    @Test
    fun `cycle skips threaded where threading is unsupported`() {
        assertEquals(FeedLayoutMode.EXPANDED, FeedLayoutMode.CONDENSED.next(supportsThreading = false))
        assertEquals(FeedLayoutMode.CONDENSED, FeedLayoutMode.EXPANDED.next(supportsThreading = false))
    }

    @Test
    fun `threaded clamps to condensed on a grid feed`() {
        assertEquals(FeedLayoutMode.CONDENSED, FeedLayoutMode.THREADED.clamped(supportsThreading = false))
        assertEquals(FeedLayoutMode.THREADED, FeedLayoutMode.THREADED.clamped(supportsThreading = true))
        assertEquals(FeedLayoutMode.EXPANDED, FeedLayoutMode.EXPANDED.clamped(supportsThreading = false))
    }

    @Test
    fun `both condensed layouts use condensed rows`() {
        assertFalse(FeedLayoutMode.EXPANDED.usesCondensedRows)
        assertTrue(FeedLayoutMode.CONDENSED.usesCondensedRows)
        assertTrue(FeedLayoutMode.THREADED.usesCondensedRows)
    }

    @Test
    fun `stored layout wins`() {
        assertEquals(
            FeedLayoutMode.THREADED,
            FeedLayoutMode.resolve(storedLayout = "threaded", storedCompact = false, defaultCompact = false),
        )
    }

    @Test
    fun `legacy compact override migrates`() {
        // Someone who had turned compact ON for this feed must not be reset.
        assertEquals(
            FeedLayoutMode.CONDENSED,
            FeedLayoutMode.resolve(storedLayout = null, storedCompact = true, defaultCompact = false),
        )
        // And someone who had turned it OFF against an ON default keeps expanded.
        assertEquals(
            FeedLayoutMode.EXPANDED,
            FeedLayoutMode.resolve(storedLayout = null, storedCompact = false, defaultCompact = true),
        )
    }

    @Test
    fun `falls back to the feed default when nothing is stored`() {
        assertEquals(FeedLayoutMode.CONDENSED, FeedLayoutMode.resolve(storedLayout = null, storedCompact = null, defaultCompact = true))
        assertEquals(FeedLayoutMode.EXPANDED, FeedLayoutMode.resolve(storedLayout = null, storedCompact = null, defaultCompact = false))
    }

    @Test
    fun `an unknown stored value falls back rather than crashing`() {
        assertEquals(
            FeedLayoutMode.CONDENSED,
            FeedLayoutMode.resolve(storedLayout = "galaxy-brain", storedCompact = true, defaultCompact = false),
        )
    }
}
