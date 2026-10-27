package com.nostrvault.data.music

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.nio.file.Files

class WavlakeCacheTest {
    private val dir: File = Files.createTempDirectory("wavlake-cache").toFile()
    private var clock = 1_000_000_000_000L
    private val asked = mutableListOf<String>()
    private var answer = "one"

    private fun cache(directory: File? = dir, loader: suspend (String) -> String = { asked += it; answer }) =
        WavlakeCache(directory, now = { clock }, loader = loader)

    @After fun cleanUp() { dir.deleteRecursively() }

    @Test fun aFreshAnswerAsksNothing() = runBlocking {
        val c = cache()
        assertEquals("one", c.data("u", maxAgeMs = 60_000))
        clock += 59_000
        assertEquals("one", c.data("u", maxAgeMs = 60_000))
        assertEquals(listOf("u"), asked)
    }

    @Test fun aStaleAnswerIsAskedForAgain() = runBlocking {
        val c = cache()
        c.data("u", maxAgeMs = 60_000)
        clock += 61_000
        answer = "two"
        assertEquals("two", c.data("u", maxAgeMs = 60_000))
        assertEquals(listOf("u", "u"), asked)
    }

    @Test fun aRelaunchReadsTheDiskWithItsAge() = runBlocking {
        cache().data("https://wavlake.com/api/v1/content/rankings?sort=sats&days=7", maxAgeMs = 60_000)
        clock += 30_000
        // A new cache over the same folder: what a relaunch sees.
        val relaunched = cache()
        val hit = relaunched.stored("https://wavlake.com/api/v1/content/rankings?sort=sats&days=7")!!
        assertEquals("one", hit.body)
        assertTrue(relaunched.isFresh(hit, maxAgeMs = 60_000))
        assertFalse(relaunched.isFresh(hit, maxAgeMs = 10_000))
        relaunched.data("https://wavlake.com/api/v1/content/rankings?sort=sats&days=7", maxAgeMs = 60_000)
        assertEquals(1, asked.size)
    }

    @Test fun memoryOnlyKeepsNothingOnDisk() = runBlocking {
        cache(directory = null).data("u", maxAgeMs = 60_000)
        assertNull(cache(directory = null).stored("u"))
        assertTrue(dir.listFiles().isNullOrEmpty())
    }

    @Test fun oneAddressAskedTwiceAtOnceIsOneRequest() = runBlocking {
        val gate = CompletableDeferred<Unit>()
        val c = cache { asked += it; gate.await(); "body" }
        val both = listOf(async { c.load("u") }, async { c.load("u") })
        gate.complete(Unit)
        assertEquals(listOf("body", "body"), both.awaitAll())
        assertEquals(1, asked.size)
    }

    @Test fun aFailureKeepsTheOldAnswerAndIsNotKept() = runBlocking {
        var down = false
        val c = cache { asked += it; if (down) throw java.io.IOException("down") else "old" }
        c.data("u", maxAgeMs = 60_000)
        clock += 61_000
        down = true
        try { c.data("u", maxAgeMs = 60_000); fail("expected the failure") } catch (_: java.io.IOException) {}
        // Still there to show, still stale, and the next try asks again.
        assertEquals("old", c.stored("u")!!.body)
        down = false
        assertEquals("old", c.data("u", maxAgeMs = 60_000))
        assertEquals(3, asked.size)
    }
}
