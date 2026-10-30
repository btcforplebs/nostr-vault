package com.nostrvault.relay

import java.io.File
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The service learns from the relay log that the last run is still shutting down. */
class RelayDrainStateTest {
    @After fun reset() = RelayDrainState.resetForTest()

    // The lines as haven-go logs them (cshared.go StopRelayC, lifecycle.go).
    private val stragglers = "2026/10/30 14:50:20 ⚠️ background goroutines still running after 2s (wot.Initialize); databases close when they finish"
    private val refused = "2026/10/30 14:50:40 🚫 StartRelayC refused: the last relay cycle is still shutting down"
    private val drained = "2026/10/30 14:51:18 ✅ last relay cycle drained; databases closed"

    @Test
    fun `stragglers or a refused start mean draining, the drained line ends it`() {
        assertFalse(RelayDrainState.isDraining)
        RelayDrainState.observe(stragglers)
        assertTrue(RelayDrainState.isDraining)
        RelayDrainState.observe("INFO Closing database name=chat")
        assertTrue(RelayDrainState.isDraining)
        RelayDrainState.observe(drained)
        assertFalse(RelayDrainState.isDraining)
        RelayDrainState.observe(refused)
        assertTrue(RelayDrainState.isDraining)
        RelayDrainState.markRunning()
        assertFalse(RelayDrainState.isDraining)
    }

    @Test
    fun `log store applies drain lines`() {
        val store = LogStore()
        store.applyLines(listOf("INFO one", stragglers))
        assertTrue(RelayDrainState.isDraining)
        store.applyLines(listOf(drained))
        assertFalse(RelayDrainState.isDraining)
    }

    @Test
    fun `await returns at once when nothing drains`() = runBlocking {
        assertFalse(RelayDrainState.awaitDrainedIfDraining(pollMs = 10))
    }

    @Test
    fun `await waits for the drained line`() = runBlocking {
        RelayDrainState.observe(refused)
        val waited = async { RelayDrainState.awaitDrainedIfDraining(pollMs = 10) }
        delay(100)
        assertFalse(waited.isCompleted)
        RelayDrainState.observe(drained)
        assertTrue(waited.await())
        assertFalse(RelayDrainState.isDraining)
    }

    @Test
    fun `await gives up when the service stops`() = runBlocking {
        RelayDrainState.observe(stragglers)
        var stopping = false
        val waited = async { RelayDrainState.awaitDrained(pollMs = 10) { stopping } }
        delay(RelayDrainState.LOG_SETTLE_MS + 50)
        stopping = true
        assertEquals(false, waited.await())
        assertTrue(RelayDrainState.isDraining)
    }

    @Test
    fun `the lines match what haven-go logs`() {
        val goDir = generateSequence(File("").absoluteFile) { it.parentFile }
            .map { File(it, "haven-go") }
            .first { File(it, "cshared.go").exists() }
        val go = File(goDir, "cshared.go").readText() + File(goDir, "lifecycle.go").readText()
        for (line in listOf(RelayDrainState.STRAGGLERS_LINE, RelayDrainState.REFUSED_LINE, RelayDrainState.DRAINED_LINE)) {
            assertTrue("haven-go no longer logs \"$line\"", go.contains(line))
        }
    }
}
