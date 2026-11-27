package com.nostrvault.service

import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.util.concurrent.atomic.AtomicInteger

/** Z1: a row's missing size is asked once per hash with HEAD and remembered (iOS twin MediaSizeCacheTests). */
class BlobSizeLookupTest {
    @get:Rule val tmp = TemporaryFolder()
    private val sha = "ab".repeat(32)
    private val url = "https://blossom.example/$sha.jpg"

    @Test fun onlyAPlain200WithALengthGivesASize() {
        assertEquals(2_457_600L, MediaSizeCache.sizeOf(200, "2457600"))
        assertEquals(12L, MediaSizeCache.sizeOf(200, " 12 "))
        assertNull(MediaSizeCache.sizeOf(206, "1"))
        assertNull(MediaSizeCache.sizeOf(404, "153"))
        assertNull(MediaSizeCache.sizeOf(200, null))
        assertNull(MediaSizeCache.sizeOf(200, "0"))
        assertNull(MediaSizeCache.sizeOf(200, "-5"))
        assertNull(MediaSizeCache.sizeOf(200, "12abc"))
    }

    @Test fun asksOnceThenAnswersFromTheCache() = runBlocking {
        val calls = AtomicInteger()
        val lookup = BlobSizeLookup(null, head = { calls.incrementAndGet(); delay(20); 200 to "999" })
        val answers = (1..5).map { async { lookup.size(sha.uppercase(), url) } }.awaitAll()
        assertEquals(List(5) { 999L }, answers)
        assertEquals(999L, lookup.size(sha, url))
        assertEquals(999L, lookup.cached(sha))
        assertEquals(1, calls.get())
    }

    @Test fun aFailedOrSizelessAnswerIsAskedAgain() = runBlocking {
        val calls = AtomicInteger()
        val replies = ArrayDeque(listOf<Pair<Int, String?>?>(null, 200 to null, 206 to "1", 200 to "50"))
        val lookup = BlobSizeLookup(null, head = { calls.incrementAndGet(); replies.removeFirst() })
        repeat(3) { assertNull(lookup.size(sha, url)) }
        assertEquals(50L, lookup.size(sha, url))
        assertEquals(4, calls.get())
    }

    @Test fun refusesBadHashesAndNonHttpLinks() = runBlocking {
        val calls = AtomicInteger()
        val lookup = BlobSizeLookup(null, head = { calls.incrementAndGet(); 200 to "1" })
        assertNull(lookup.size("nothex", url))
        assertNull(lookup.size(sha, "blossom:$sha.jpg"))
        assertEquals(0, calls.get())
    }

    @Test fun keptOnDiskAcrossARelaunch() = runBlocking {
        val file = tmp.root.resolve("media_sizes.json")
        BlobSizeLookup(file, head = { 200 to "321" }).size(sha, url)
        var waited = 0
        while (!file.exists() && waited < 50) { delay(100); waited++ }
        assertTrue(file.exists())
        val again = BlobSizeLookup(file, head = { error("should not ask") })
        assertEquals(321L, again.size(sha, url))
    }

    @Test fun pruneKeepsTheNewest() {
        val cache = MediaSizeCache((0 until MediaSizeCache.MAX_ENTRIES + 3).associate { i ->
            "%064x".format(i) to MediaSizeCache.Entry(i + 1L, i.toLong())
        })
        val pruned = cache.pruned()
        assertEquals(MediaSizeCache.MAX_ENTRIES, pruned.entries.size)
        assertNull(pruned.size("%064x".format(0)))
    }
}
