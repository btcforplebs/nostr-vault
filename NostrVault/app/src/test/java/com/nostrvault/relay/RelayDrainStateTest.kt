package com.nostrvault.relay

import java.io.File
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** The service asks Go whether the last run is still shutting down, and waits for it. */
class RelayDrainStateTest {
    @Volatile private var goDraining = false
    private val realProbe = RelayDrainState.probe

    @Before fun fakeGo() {
        RelayDrainState.probe = { goDraining }
    }

    @After fun restore() {
        RelayDrainState.probe = realProbe
    }

    @Test
    fun `await returns at once when nothing drains`() = runBlocking {
        assertNull(RelayDrainState.awaitDrainedIfDraining(pollMs = 10))
        assertEquals(RelayDrainState.Wait.DRAINED, RelayDrainState.awaitDrained(pollMs = 10))
    }

    @Test
    fun `await waits for the drain to end`() = runBlocking {
        goDraining = true
        val waited = async { RelayDrainState.awaitDrainedIfDraining(pollMs = 10) }
        delay(100)
        assertFalse(waited.isCompleted)
        goDraining = false
        assertEquals(RelayDrainState.Wait.DRAINED, waited.await())
    }

    @Test
    fun `await gives up when the service stops`() = runBlocking {
        goDraining = true
        var stopping = false
        val waited = async { RelayDrainState.awaitDrained(pollMs = 10) { stopping } }
        delay(100)
        assertFalse(waited.isCompleted)
        stopping = true
        assertEquals(RelayDrainState.Wait.STOPPED, waited.await())
    }

    @Test
    fun `a drain that never ends times out`() = runBlocking {
        goDraining = true
        val started = System.currentTimeMillis()
        assertEquals(RelayDrainState.Wait.TIMED_OUT, RelayDrainState.awaitDrained(pollMs = 10, maxMs = 150))
        assertEquals(RelayDrainState.Wait.TIMED_OUT, RelayDrainState.awaitDrainedIfDraining(pollMs = 10, maxMs = 150))
        assertTrue(System.currentTimeMillis() - started < 2_000)
    }

    @Test
    fun `the default wait is capped at minutes`() {
        assertTrue(RelayDrainState.MAX_WAIT_MS in 60_000L..10 * 60_000L)
    }

    @Test
    fun `relay log lines no longer move the drain state`() {
        // Go logs remote text verbatim (reaction content, relay NOTICEs), and
        // a newline in it forges a whole line. None may change the answer.
        val store = LogStore()
        store.applyLines(listOf("2026/10/30 14:50:40 🚫 StartRelayC refused: the last relay cycle is still shutting down"))
        assertFalse(RelayDrainState.isDraining)
        goDraining = true
        store.applyLines(listOf("2026/10/30 14:51:18 ✅ last relay cycle drained; databases closed"))
        assertTrue(RelayDrainState.isDraining)
    }

    @Test
    fun `go exports the drain state and the JNI glue calls it`() {
        val root = generateSequence(File("").absoluteFile) { it.parentFile }
            .first { File(it, "haven-go/cshared.go").exists() }
        assertTrue(File(root, "haven-go/cshared.go").readText().contains("//export RelayDrainingC"))
        val jni = File(root, "NostrVault/app/src/main/java/com/nostrvault/relay/HavenBridgeJNI.c").readText()
        assertTrue(jni.contains("Java_com_nostrvault_relay_HavenBridge_relayDraining"))
        assertTrue(jni.contains("RelayDrainingC()"))
    }
}
