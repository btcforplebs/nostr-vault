package com.nostrvault.relay

import java.io.File
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The relay's stop runs off the caller's thread, and a start waits for it. */
class RelayStopperTest {

    @Test
    fun `stopAsync returns at once while Go's stop blocks`() = runBlocking {
        val stopper = RelayStopper()
        val release = CountDownLatch(1)
        val started = System.nanoTime()
        val job = stopper.stopAsync { release.await(10, TimeUnit.SECONDS) }
        val tookMs = (System.nanoTime() - started) / 1_000_000
        assertTrue("stopAsync blocked the caller for $tookMs ms", tookMs < 500)
        assertTrue(stopper.isStopping)
        release.countDown()
        withTimeout(5_000) { job.join() }
        assertFalse(stopper.isStopping)
    }

    @Test
    fun `a start waits for the pending stop`() = runBlocking {
        val stopper = RelayStopper()
        val release = CountDownLatch(1)
        val order = Collections.synchronizedList(mutableListOf<String>())
        stopper.stopAsync { release.await(10, TimeUnit.SECONDS); order += "stop" }
        val start = async { stopper.awaitPending(); order += "start" }
        delay(150)
        assertFalse("start ran before the stop returned", start.isCompleted)
        release.countDown()
        withTimeout(5_000) { start.await() }
        assertEquals(listOf("stop", "start"), order)
    }

    @Test
    fun `awaitPending returns at once with no stop`() = runBlocking {
        withTimeout(500) { RelayStopper().awaitPending() }
    }

    @Test
    fun `two stops run in order`() = runBlocking {
        val stopper = RelayStopper()
        val first = CountDownLatch(1)
        val order = Collections.synchronizedList(mutableListOf<String>())
        stopper.stopAsync { first.await(10, TimeUnit.SECONDS); order += "first" }
        stopper.stopAsync { order += "second" }
        delay(100)
        assertTrue(order.isEmpty())
        first.countDown()
        withTimeout(5_000) { stopper.awaitPending() }
        assertEquals(listOf("first", "second"), order)
    }

    @Test
    fun `onDestroy never blocks on the Go stop, and starts wait for it`() {
        val service = File("src/main/java/com/nostrvault/relay/RelayForegroundService.kt").readText()
        val onDestroy = service.substringAfter("override fun onDestroy()").substringBefore("super.onDestroy()")
        assertFalse("onDestroy blocks the main thread", "runBlocking" in onDestroy)
        assertTrue("onDestroy must stop through the stopper", "stopper.stopAsync" in onDestroy)
        val startup = File("src/main/java/com/nostrvault/relay/RelayForegroundServiceStartup.kt").readText()
        assertTrue(Regex("""awaitPendingStop\(\)\s+HavenBridge\.startRelay\(importMode = false\)""").containsMatchIn(startup))
        val import = File("src/main/java/com/nostrvault/service/RelayImportService.kt").readText()
        assertTrue(Regex("""awaitPendingStop\(\)\s+// This blocks until import completes\s+HavenBridge\.startRelay\(importMode = true\)""").containsMatchIn(import))
    }
}
