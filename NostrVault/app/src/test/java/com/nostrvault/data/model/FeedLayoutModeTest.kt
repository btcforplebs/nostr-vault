package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors iOS `FeedLayoutModeTests.swift`. Compact View is gone (Logen, 2026-11-11). */
class FeedLayoutModeTest {

    @Test
    fun `only expanded and threaded are left`() {
        assertEquals(listOf(FeedLayoutMode.EXPANDED, FeedLayoutMode.THREADED), FeedLayoutMode.entries)
    }

    @Test
    fun `the button toggles expanded and threaded on a timeline`() {
        assertEquals(FeedLayoutMode.THREADED, FeedLayoutMode.EXPANDED.next(supportsThreading = true))
        assertEquals(FeedLayoutMode.EXPANDED, FeedLayoutMode.THREADED.next(supportsThreading = true))
        assertEquals("Threaded View", FeedLayoutMode.EXPANDED.nextDisplayName(supportsThreading = true))
        assertEquals("Expanded View", FeedLayoutMode.THREADED.nextDisplayName(supportsThreading = true))
    }

    @Test
    fun `a feed that cannot thread stays expanded`() {
        assertEquals(FeedLayoutMode.EXPANDED, FeedLayoutMode.EXPANDED.next(supportsThreading = false))
        assertEquals(FeedLayoutMode.EXPANDED, FeedLayoutMode.THREADED.next(supportsThreading = false))
        assertEquals(FeedLayoutMode.EXPANDED, FeedLayoutMode.THREADED.clamped(supportsThreading = false))
        assertEquals(FeedLayoutMode.THREADED, FeedLayoutMode.THREADED.clamped(supportsThreading = true))
    }

    @Test
    fun `expanded starts with replies off and threaded with them on`() {
        assertFalse(FeedLayoutMode.EXPANDED.showsRepliesByDefault)
        assertTrue(FeedLayoutMode.THREADED.showsRepliesByDefault)
    }

    @Test
    fun `stored layout wins`() {
        assertEquals(FeedLayoutMode.THREADED, FeedLayoutMode.resolve("threaded"))
        assertEquals(FeedLayoutMode.EXPANDED, FeedLayoutMode.resolve("expanded"))
    }

    @Test
    fun `a saved condensed layout reads as expanded`() {
        assertEquals(FeedLayoutMode.EXPANDED, FeedLayoutMode.resolve("condensed"))
        assertEquals(FeedLayoutMode.EXPANDED, FeedLayoutMode.fromStorageKey("condensed"))
    }

    @Test
    fun `nothing stored or an unknown value falls back to expanded rather than crashing`() {
        assertEquals(FeedLayoutMode.EXPANDED, FeedLayoutMode.resolve(null))
        assertEquals(FeedLayoutMode.EXPANDED, FeedLayoutMode.resolve("galaxy-brain"))
        assertNull(FeedLayoutMode.fromStorageKey("galaxy-brain"))
    }

    @Test
    fun `migration rewrites condensed feeds and leaves the rest`() {
        val migrated = FeedLayoutMode.migrateCondensed(
            mapOf("FOLLOWING" to "condensed", "GLOBAL" to "threaded", "ARTICLES" to "expanded"),
        )
        assertEquals(mapOf("FOLLOWING" to "expanded", "GLOBAL" to "threaded", "ARTICLES" to "expanded"), migrated)
    }

    @Test
    fun `migration runs once`() {
        val once = FeedLayoutMode.migrateCondensed(mapOf("FOLLOWING" to "condensed"))!!
        assertNull(FeedLayoutMode.migrateCondensed(once))
        assertNull(FeedLayoutMode.migrateCondensed(emptyMap()))
        assertNull(FeedLayoutMode.migrateCondensed(mapOf("FOLLOWING" to "threaded")))
    }
}
