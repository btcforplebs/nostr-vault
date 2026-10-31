package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenConfig
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.concurrent.atomic.AtomicInteger

/**
 * The photo screen's Blossom answers: kept a day on disk, reused by a swipe or
 * a relaunch, never kept when a server could not be asked. Port of iOS
 * `BlossomPresenceDisk` (Tim, 1391).
 */
class BlossomPresenceCacheTest {
    @get:Rule val tmp = TemporaryFolder()

    private val hash = "ab".repeat(32)
    private val start = 1_800_000_000_000L
    private val day = BlossomPresenceDisk.MAX_AGE_MS

    // ── Pure rules ─────────────────────────────────────────────────────

    @Test fun freshForADayThenStale() {
        val disk = BlossomPresenceDisk().storing(hash, mapOf("s1" to BlobPresence.PRESENT, "s2" to BlobPresence.ABSENT), start)
        assertTrue(disk.isFresh(hash, start + day - 1))
        assertFalse(disk.isFresh(hash, start + day))
        assertFalse(disk.isFresh("other", start))
        assertEquals(mapOf("s1" to true, "s2" to false), disk.entries[hash]?.servers)
        assertEquals(mapOf(hash to mapOf("s1" to BlobPresence.PRESENT, "s2" to BlobPresence.ABSENT)), disk.presence())
    }

    @Test fun anUnreachableServerIsNotKept() {
        val disk = BlossomPresenceDisk()
            .storing(hash, mapOf("s1" to BlobPresence.PRESENT), start)
            .storing(hash, mapOf("s1" to BlobPresence.PRESENT, "down" to BlobPresence.UNREACHABLE), start)
        assertNull(disk.entries[hash])
        assertNull(BlossomPresenceDisk().storing(hash, emptyMap(), start).entries[hash])
    }

    @Test fun pruneDropsOldAndKeepsNewest() {
        var disk = BlossomPresenceDisk().storing("old", mapOf("s" to BlobPresence.PRESENT), start)
        val later = start + 30 * 3_600_000L
        for (i in 0 until BlossomPresenceDisk.MAX_ENTRIES + 5) {
            disk = disk.storing("h$i", mapOf("s" to BlobPresence.PRESENT), later + i)
        }
        val pruned = disk.pruned(later + 10_000)
        assertNull(pruned.entries["old"])
        assertEquals(BlossomPresenceDisk.MAX_ENTRIES, pruned.entries.size)
        assertNull(pruned.entries["h0"])
        assertTrue("h${BlossomPresenceDisk.MAX_ENTRIES + 4}" in pruned.entries)
    }

    @Test fun reusableOnlyWhenEveryServerAnswered() {
        val mirrors = listOf("s1", "s2")
        assertTrue(reusablePresence(mapOf("s1" to BlobPresence.PRESENT, "s2" to BlobPresence.ABSENT), mirrors))
        assertFalse(reusablePresence(mapOf("s1" to BlobPresence.PRESENT), mirrors))
        assertFalse(reusablePresence(mapOf("s1" to BlobPresence.PRESENT, "s2" to BlobPresence.UNREACHABLE), mirrors))
    }

    // ── Store on disk ──────────────────────────────────────────────────

    @Test fun answersSurviveARelaunchForADay() = runBlocking {
        val file = File(tmp.root, "blossom_presence.json")
        var now = start
        val first = BlossomPresenceStore(file) { now }
        first.load()
        first.record(hash, mapOf("s1" to BlobPresence.PRESENT), this)
        // The write waits for the burst to end.
        assertFalse(file.exists())
        kotlinx.coroutines.delay(2_500)
        assertTrue(file.exists())

        val relaunched = BlossomPresenceStore(file) { now }
        assertEquals(mapOf(hash to mapOf("s1" to BlobPresence.PRESENT)), relaunched.load().presence())
        assertTrue(relaunched.isFresh(hash))

        now = start + day
        assertTrue(BlossomPresenceStore(file) { now }.load().entries.isEmpty())
    }

    @Test fun anUnreadableFileIsAnEmptyCache() {
        val file = File(tmp.root, "blossom_presence.json").apply { writeText("not json") }
        assertTrue(BlossomPresenceStore(file) { start }.load().entries.isEmpty())
    }

    // ── The service asks only when it has to ──────────────────────────

    private val gets = AtomicInteger()
    private var status = 200
    private val server = MockWebServer().apply {
        dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                gets.incrementAndGet()
                return MockResponse().setResponseCode(status).setHeader("Content-Type", "image/jpeg").setBody("x")
            }
        }
        start()
    }

    @After fun stop() = server.shutdown()

    private fun service(store: BlossomPresenceStore): BlossomService {
        val configStore = mockk<ConfigStore>(relaxed = true)
        val mirror = server.url("/").toString().trimEnd('/')
        every { configStore.config } returns MutableStateFlow(HavenConfig(ownerNpub = "npub1owner", blossomMirrors = listOf(mirror)))
        return BlossomService(
            configStore, mockk(relaxed = true), mockk(relaxed = true), mockk(relaxed = true), mockk(relaxed = true),
            presenceStore = store,
        )
    }

    @Test fun aSwipeReusesTheAnswerAndAnActionAsksAgain() = runBlocking {
        val blossom = service(BlossomPresenceStore(file = null))
        blossom.checkMirrorStatus(hash, force = false)
        assertEquals(1, gets.get())
        // Swiping back to the photo: no call.
        assertEquals(listOf(true), blossom.checkMirrorStatus(hash, force = false).values.toList())
        assertEquals(1, gets.get())
        // After a push or delete the viewer forces a fresh answer.
        blossom.checkMirrorStatus(hash)
        assertEquals(2, gets.get())
    }

    @Test fun aServerThatCouldNotBeAskedIsAskedAgain() = runBlocking {
        val blossom = service(BlossomPresenceStore(file = null))
        status = 503
        blossom.checkMirrorPresence(hash)
        status = 200
        assertEquals(BlobPresence.PRESENT, blossom.checkMirrorPresence(hash).values.single())
        assertEquals(2, gets.get())
    }

    @Test fun aRelaunchShowsYesterdaysAnswerWithoutAsking() = runBlocking {
        val file = File(tmp.root, "blossom_presence.json")
        var now = start
        service(BlossomPresenceStore(file) { now }).checkMirrorPresence(hash)
        kotlinx.coroutines.delay(2_500)
        assertEquals(1, gets.get())

        now = start + day - 60_000
        val relaunched = service(BlossomPresenceStore(file) { now })
        // The saved answers load off the main thread at start.
        repeat(50) { if (relaunched.mirrorPresence.value.isEmpty()) kotlinx.coroutines.delay(20) }
        assertEquals(BlobPresence.PRESENT, relaunched.checkMirrorPresence(hash).values.single())
        assertEquals(1, gets.get())

        // A day on, the photo screen asks again.
        now = start + day
        relaunched.checkMirrorPresence(hash)
        assertEquals(2, gets.get())
    }

    // ── Auto-Mirror ────────────────────────────────────────────────────

    @Test fun autoMirrorRunsAtMostEveryThreeHours() {
        val three = BlossomService.AUTO_MIRROR_EVERY_MS
        assertTrue(BlossomService.autoMirrorDue(lastImport = null, now = start))
        assertFalse(BlossomService.autoMirrorDue(lastImport = start, now = start + three - 1))
        assertTrue(BlossomService.autoMirrorDue(lastImport = start, now = start + three))
        // A clock set back doesn't hold it off for good.
        assertTrue(BlossomService.autoMirrorDue(lastImport = start, now = start - 1))
    }
}
