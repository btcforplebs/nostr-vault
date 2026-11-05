package com.nostrvault.service

import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.IOException
import java.util.concurrent.Executors

/** Audit #17: a picked zip is copied off the caller's thread, and never left in the cache. */
class PickedZipTest {
    @get:Rule val tmp = TemporaryFolder()

    private val io = Executors.newSingleThreadExecutor { Thread(it, "picked-zip-io") }.asCoroutineDispatcher()

    @Test
    fun `the copy runs on the io dispatcher and is gone after the restore`() = runBlocking {
        val cache = tmp.newFolder("cache")
        var copiedOn = ""
        val got = PickedZip.use(cache, { copiedOn = Thread.currentThread().name; ByteArrayInputStream(byteArrayOf(1, 2, 3)) }, io) { f ->
            assertTrue(f.exists())
            f.readBytes().size
        }
        assertEquals(3, got)
        assertTrue(copiedOn, copiedOn.startsWith("picked-zip-io"))
        assertEquals(0, cache.listFiles()!!.size)
    }

    @Test
    fun `a restore that throws still leaves nothing behind`() = runBlocking {
        val cache = tmp.newFolder("cache")
        try {
            PickedZip.use(cache, { ByteArrayInputStream(ByteArray(10)) }, io) { error("restore failed") }
            fail()
        } catch (e: IllegalStateException) {
            assertEquals("restore failed", e.message)
        }
        assertEquals(0, cache.listFiles()!!.size)
    }

    @Test
    fun `a restore cancelled when the screen closes still leaves nothing behind`() = runBlocking {
        val cache = tmp.newFolder("cache")
        val started = kotlinx.coroutines.CompletableDeferred<Unit>()
        val job = launch {
            PickedZip.use(cache, { ByteArrayInputStream(ByteArray(10)) }, io) {
                started.complete(Unit)
                kotlinx.coroutines.awaitCancellation()
            }
        }
        started.await()
        job.cancelAndJoin()
        assertEquals(0, cache.listFiles()!!.size)
    }

    @Test
    fun `a picked file that can't be opened is an error, not a crash, and leaves nothing`() = runBlocking {
        val cache = tmp.newFolder("cache")
        for (open in listOf<() -> java.io.InputStream?>({ null }, { throw SecurityException("revoked") })) {
            try {
                PickedZip.use(cache, open, io) { fail("used") }
                fail()
            } catch (e: IOException) {
                assertEquals("Could not open the backup file", e.message)
            }
        }
        assertEquals(0, cache.listFiles()!!.size)
    }

    @Test
    fun `the sweep takes what a kill left, and nothing else`() {
        val cache = tmp.newFolder("cache")
        val left = listOf("picked-123.zip", "restore_backup.zip", "media_import.zip").map { java.io.File(cache, it).apply { writeText("x") } }
        val kept = java.io.File(cache, "gif-1.gif").apply { writeText("x") }
        PickedZip.sweep(cache)
        assertTrue(left.none { it.exists() })
        assertTrue(kept.exists())
    }
}
