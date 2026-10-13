package com.nostrvault.service

import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedNote
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Each feed kept for a switch back (iOS FeedService+ModeCache). */
class FeedModeCachesTest {
    private fun note(id: String, at: Long) = FeedNote.fromEvent(id.padEnd(64, '0'), "a".repeat(64), id, emptyList(), at, 1)
    private var clock = 0L
    private val caches = FeedModeCaches { clock }

    @Test
    fun `a feed comes back with its age while it is under fifteen minutes old`() {
        val notes = listOf(note("a", 2), note("b", 1))
        caches.put("me|FOLLOWING", notes, emptyMap(), emptyMap())
        clock = FeedModeCaches.MAX_AGE_MS - 1
        val (cache, age) = caches.take("me|FOLLOWING")!!
        assertEquals(notes, cache.notes)
        assertEquals(FeedModeCaches.MAX_AGE_MS - 1, age)
    }

    @Test
    fun `at fifteen minutes the feed is dropped and loads as before`() {
        caches.put("me|GLOBAL", listOf(note("a", 1)), emptyMap(), emptyMap())
        clock = FeedModeCaches.MAX_AGE_MS
        assertNull(caches.take("me|GLOBAL"))
        clock = 0
        assertNull(caches.take("me|GLOBAL"))
    }

    @Test
    fun `another account or feed finds nothing, and an empty feed is not kept`() {
        caches.put("me|FOLLOWING", listOf(note("a", 1)), emptyMap(), emptyMap())
        caches.put("me|POPULAR", emptyList(), emptyMap(), emptyMap())
        assertNull(caches.take("you|FOLLOWING"))
        assertNull(caches.take("me|GLOBAL"))
        assertNull(caches.take("me|POPULAR"))
    }

    @Test
    fun `what was on screen is kept even when it is older than the newest raw notes`() {
        val shown = note("shown", 1)
        val pending = note("pending", 500)
        val raw = (0 until 300).map { note("raw$it", 1_000L - it) }
        val kept = FeedModeCaches.notesToKeep(listOf(shown), listOf(pending), raw + shown)
        assertTrue(shown in kept)
        assertTrue(pending in kept)
        assertEquals(FeedModeCaches.RAW_KEPT + 2, kept.size)
        assertEquals(kept.sortedByDescending { it.createdAt }, kept)
    }

    @Test
    fun `only the note-list feeds are cached`() {
        assertTrue(FeedModeCaches.usesNotePipeline(FeedMode.POPULAR))
        assertTrue(FeedModeCaches.usesNotePipeline(FeedMode.FOLLOWING))
        assertFalse(FeedModeCaches.usesNotePipeline(FeedMode.REELS))
        assertFalse(FeedModeCaches.usesNotePipeline(FeedMode.MUSIC))
    }

    @Test
    fun `Popular stays as it was for five minutes`() {
        assertEquals(5 * 60 * 1000L, FeedModeCaches.POPULAR_FRESH_MS)
        assertEquals(15 * 60 * 1000L, FeedModeCaches.MAX_AGE_MS)
    }

    @Test
    fun `ranks count scored posts in the order shown`() {
        val ranks = FeedFilterEngine.popularRanks(
            ids = listOf("top", "reply", "second", "top"),
            scores = mapOf("top" to 9.0, "second" to 4.0, "unshown" to 99.0),
        )
        assertEquals(mapOf("top" to 1, "second" to 2), ranks)
    }
}
