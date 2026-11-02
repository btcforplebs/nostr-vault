package com.nostrvault.service

import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.NoteStats
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Feed speed (3.1.0): resume from the newest note, Discover / Popular saved to disk. */
class FeedSpeedTest {
    private fun note(id: String, at: Long) = FeedNote.fromEvent(id.padEnd(64, '0'), "a".repeat(64), id, emptyList(), at, 1)
    private var clock = 0L
    private val caches = FeedModeCaches { clock }

    @Test
    fun `resume starts a minute before the newest note, and not at all without one`() {
        assertEquals(1_000L - 60, FeedResumeSince.from(1_000L))
        assertNull(FeedResumeSince.from(null))
        assertNull(FeedResumeSince.from(0L))
    }

    @Test
    fun `a round is complete only once every connected relay has answered`() {
        assertFalse(FeedResumeSince.roundComplete(setOf("local"), setOf("local", "damus")))
        assertTrue(FeedResumeSince.roundComplete(setOf("local", "damus"), setOf("local", "damus")))
        // A relay that dropped after answering still counts; one that never connected does not hold it up.
        assertTrue(FeedResumeSince.roundComplete(setOf("local", "damus"), setOf("local")))
        assertFalse(FeedResumeSince.roundComplete(emptySet(), emptySet()))
    }

    @Test
    fun `a cache filed mid-load keeps no resume key, one filed after keeps it`() {
        assertNull(caches.put("me|DISCOVERY", listOf(note("a", 1)), emptyMap(), emptyMap())!!.feedKey)
        assertEquals("k", caches.put("me|DISCOVERY", listOf(note("a", 1)), emptyMap(), emptyMap(), "k")!!.feedKey)
        assertNull(caches.put("me|POPULAR", emptyList(), emptyMap(), emptyMap()))
    }

    @Test
    fun `a saved feed outlives the fifteen minute tab cache, up to the snapshot age`() {
        caches.putSaved("me|POPULAR", ModeFeedCache(listOf(note("a", 1)), emptyMap(), emptyMap(), 0L))
        caches.put("me|GLOBAL", listOf(note("b", 1)), emptyMap(), emptyMap())
        clock = FeedModeCaches.MAX_AGE_MS
        assertNull(caches.take("me|GLOBAL"))
        val (cache, age) = caches.take("me|POPULAR")!!
        assertTrue(cache.fromDisk)
        assertEquals(FeedModeCaches.MAX_AGE_MS, age)
        clock = FeedModeCaches.DISK_MAX_AGE_MS
        assertNull(caches.take("me|POPULAR"))
    }

    @Test
    fun `a saved feed never replaces one filed since the launch`() {
        caches.put("me|DISCOVERY", listOf(note("new", 2)), emptyMap(), emptyMap())
        caches.putSaved("me|DISCOVERY", ModeFeedCache(listOf(note("old", 1)), emptyMap(), emptyMap(), 0L))
        val (cache, _) = caches.take("me|DISCOVERY")!!
        assertFalse(cache.fromDisk)
        assertEquals("new".padEnd(64, '0'), cache.notes.single().id)
    }

    @Test
    fun `a feed round-trips through disk, capped at the snapshot size with only its own stats`() {
        val notes = (0 until 250).map { note("n$it-", 1_000L - it) }
        val stats = mapOf(notes[0].id to NoteStats(), "gone".padEnd(64, '0') to NoteStats())
        val scores = mapOf(notes[0].id to 3.5, notes[249].id to 1.0)
        val cache = ModeFeedCache(notes, stats, scores, capturedAtMs = 42L, feedKey = "me|POPULAR#1")
        val json = Json { ignoreUnknownKeys = true }
        val text = json.encodeToString(DiskModeCache.serializer(), FeedModeCacheDisk.toDisk(cache))
        val back = FeedModeCacheDisk.fromDisk(json.decodeFromString(DiskModeCache.serializer(), text))
        assertEquals(FeedService.SNAPSHOT_MAX_NOTES, back.notes.size)
        assertEquals(notes.take(FeedService.SNAPSHOT_MAX_NOTES).map { it.id }, back.notes.map { it.id })
        assertEquals(setOf(notes[0].id), back.noteStats.keys)
        assertEquals(mapOf(notes[0].id to 3.5), back.popularNoteScores)
        assertEquals(42L, back.capturedAtMs)
        assertEquals("me|POPULAR#1", back.feedKey)
        assertTrue(back.fromDisk)
    }

    @Test
    fun `file names keep to safe characters and differ per account and feed`() {
        val a = FeedModeCacheDisk.fileName("ab12|DISCOVERY")
        assertEquals("feed_mode_ab12_DISCOVERY.json", a)
        assertNotNull(a)
        assertTrue(a != FeedModeCacheDisk.fileName("ab12|POPULAR"))
        assertTrue(a != FeedModeCacheDisk.fileName("cd34|DISCOVERY"))
    }
}
