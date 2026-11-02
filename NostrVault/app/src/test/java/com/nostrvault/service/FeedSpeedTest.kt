package com.nostrvault.service

import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.NoteStats
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
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
    fun `a round is complete only once every relay it started with has answered or failed`() {
        val round = setOf("local", "damus", "nos")
        // The local relay answers while the remotes still wait out their stagger: not complete.
        assertFalse(FeedResumeSince.roundComplete(round, setOf("local"), emptySet()))
        assertFalse(FeedResumeSince.roundComplete(round, setOf("local", "damus"), emptySet()))
        assertTrue(FeedResumeSince.roundComplete(round, setOf("local", "damus", "nos"), emptySet()))
        // A relay whose dial failed no longer holds the round open.
        assertTrue(FeedResumeSince.roundComplete(round, setOf("local", "damus"), setOf("nos")))
        // Nobody answered, or only a relay from another round: not complete.
        assertFalse(FeedResumeSince.roundComplete(round, emptySet(), round))
        assertFalse(FeedResumeSince.roundComplete(setOf("local"), setOf("old"), emptySet()))
        assertFalse(FeedResumeSince.roundComplete(emptySet(), setOf("local"), emptySet()))
    }

    @Test
    fun `notes are filed only for the account they belong to`() {
        // Between the switch to B and the reset, the list is still A's.
        assertFalse(FeedModeCaches.ownsNotes("aaaa", "bbbb"))
        assertTrue(FeedModeCaches.ownsNotes("bbbb", "bbbb"))
        // Before any switch, whoever is active; nobody when no account decodes.
        assertTrue(FeedModeCaches.ownsNotes(null, "aaaa"))
        assertFalse(FeedModeCaches.ownsNotes(null, ""))
        assertFalse(FeedModeCaches.ownsNotes("aaaa", ""))
    }

    @Test
    fun `resume relays are kept only with a resume key`() {
        val relays = setOf("local", "damus")
        assertEquals(relays, caches.put("me|DISCOVERY", listOf(note("a", 1)), emptyMap(), emptyMap(), "k", relays)!!.feedRelays)
        assertEquals(emptySet<String>(), caches.put("me|DISCOVERY", listOf(note("a", 1)), emptyMap(), emptyMap(), null, relays)!!.feedRelays)
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
        val cache = ModeFeedCache(notes, stats, scores, capturedAtMs = 42L, feedKey = "me|POPULAR#1", feedRelays = setOf("local"))
        val json = Json { ignoreUnknownKeys = true }
        val text = json.encodeToString(DiskModeCache.serializer(), FeedModeCacheDisk.toDisk(cache))
        val back = FeedModeCacheDisk.fromDisk(json.decodeFromString(DiskModeCache.serializer(), text))
        assertEquals(FeedService.SNAPSHOT_MAX_NOTES, back.notes.size)
        assertEquals(notes.take(FeedService.SNAPSHOT_MAX_NOTES).map { it.id }, back.notes.map { it.id })
        assertEquals(setOf(notes[0].id), back.noteStats.keys)
        assertEquals(mapOf(notes[0].id to 3.5), back.popularNoteScores)
        assertEquals(42L, back.capturedAtMs)
        assertEquals("me|POPULAR#1", back.feedKey)
        assertEquals(setOf("local"), back.feedRelays)
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

    @Test
    fun `a mention counts only for the account it p-tags`() {
        val json = Json { ignoreUnknownKeys = true }
        val ev = json.parseToJsonElement("""{"id":"x","tags":[["e","y"],["p","alice"]]}""").jsonObject
        assertTrue(FeedAccountGuard.mentions(ev, "alice"))
        assertFalse(FeedAccountGuard.mentions(ev, "bob"))
        assertFalse(FeedAccountGuard.mentions(ev, ""))
        assertFalse(FeedAccountGuard.mentions(json.parseToJsonElement("""{"id":"x"}""").jsonObject, "alice"))
    }
}
