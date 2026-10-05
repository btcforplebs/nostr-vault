package com.nostrvault.relay

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** What decides a settings restart (launch inputs) and when it fires. */
@OptIn(ExperimentalCoroutinesApi::class)
class RelayConfigApplierTest {

    private val dir = File("/data/relay_data")
    private val base = HavenConfig(ownerNpub = "npub1owner")
    private fun inputs(c: HavenConfig) = RelayConfiguration.launchInputs(c, dir)

    // ── Launch inputs ─────────────────────────────────────────────

    @Test
    fun `app-side settings leave the relay's start unchanged`() {
        val appSide = listOf(
            base.copy(feedRelays = listOf("wss://feed.example")),
            base.copy(activeAccountNpub = "npub1other"),
            base.copy(blockedNpubs = listOf("npub1blocked")),
            base.copy(autoplayVideos = !base.autoplayVideos),
            base.copy(cacheTTLDays = base.cacheTTLDays + 1),
        )
        for (c in appSide) assertEquals(c.toString(), inputs(base), inputs(c))
    }

    @Test
    fun `relay-facing settings change the relay's start`() {
        val relayFacing = listOf(
            base.copy(outboxMaxEventsPerMinute = base.outboxMaxEventsPerMinute + 10),
            base.copy(outboxMaxConnectionsPerMinute = base.outboxMaxConnectionsPerMinute + 1),
            base.copy(chatRelayWotDepth = base.chatRelayWotDepth + 1),
            base.copy(chatRelayMinFollowers = base.chatRelayMinFollowers + 1),
            base.copy(wotRefreshInterval = "1h"),
            base.copy(importStartDate = "2024-01-01"),
            base.copy(relayPort = 4000),
            base.copy(logLevel = "debug"),
            base.copy(importSeedRelays = base.importSeedRelays + "wss://seed.example"),
            base.copy(blastrRelays = base.blastrRelays + "wss://blast.example"),
            base.copy(dmRelays = base.dmRelays + "wss://dm.example"),
            // The relay copies from the Mac itself (MAC_RELAY_URL), as on iOS.
            base.copy(macRelayURL = "wss://mac.example"),
        )
        for (c in relayFacing) assertNotEquals(c.toString(), inputs(base), inputs(c))
    }

    // ── Restart scheduling ────────────────────────────────────────

    /** A relay that restarts onto whatever was last saved to "disk". */
    private inner class Harness(val scope: TestScope, applierScope: CoroutineScope = scope) {
        var running: RelayConfiguration.LaunchInputs? = inputs(base)
        var disk: HavenConfig = base
        val restartStarts = mutableListOf<Long>()
        val restartedOnto = mutableListOf<HavenConfig>()

        val applier = RelayConfigApplier(
            scope = applierScope,
            now = { scope.testScheduler.currentTime },
            launchedInputs = { running },
            inputsFor = ::inputs,
            restart = {
                restartStarts += scope.testScheduler.currentTime
                val onto = disk
                delay(RESTART_MS)
                running = inputs(onto)
                restartedOnto += onto
            },
        )

        fun save(c: HavenConfig) {
            disk = c
            applier.configSaved(c)
        }
    }

    @Test
    fun `an app-side save never restarts the relay`() = runTest {
        val h = Harness(this)
        h.save(base.copy(feedRelays = listOf("wss://feed.example")))
        advanceUntilIdle()
        assertTrue(h.restartStarts.isEmpty())
    }

    @Test
    fun `a relay-facing save restarts once, after the quiet period`() = runTest {
        val h = Harness(this)
        val changed = base.copy(outboxMaxEventsPerMinute = 200)
        h.save(changed)
        advanceTimeBy(QUIET - 1)
        runCurrent()
        assertTrue("restarted before the quiet period", h.restartStarts.isEmpty())
        advanceUntilIdle()
        assertEquals(listOf(QUIET), h.restartStarts)
        assertEquals(listOf(changed), h.restartedOnto)
    }

    @Test
    fun `stepping a value restarts once onto the last step`() = runTest {
        val h = Harness(this)
        // Port typed digit by digit, or a stepper tapped, one second apart.
        for ((i, port) in listOf(3, 33, 335, 3356).withIndex()) {
            if (i > 0) advanceTimeBy(1_000)
            h.save(base.copy(relayPort = port))
        }
        advanceUntilIdle()
        assertEquals(listOf(3_000L + QUIET), h.restartStarts)
        assertEquals(3356, h.restartedOnto.single().relayPort)
    }

    @Test
    fun `app-side saves do not starve a pending restart`() = runTest {
        val h = Harness(this)
        val changed = base.copy(chatRelayWotDepth = base.chatRelayWotDepth + 1)
        h.save(changed)
        repeat(10) { n ->
            advanceTimeBy(500)
            h.save(changed.copy(feedRelays = listOf("wss://feed$n.example")))
        }
        advanceUntilIdle()
        assertEquals(listOf(QUIET), h.restartStarts)
    }

    @Test
    fun `saves during a restart fold into one follow-up after the minimum gap`() = runTest {
        val h = Harness(this)
        h.save(base.copy(outboxMaxEventsPerMinute = 200))
        advanceTimeBy(QUIET + 100)  // restart in flight
        runCurrent()
        assertEquals(1, h.restartStarts.size)
        h.save(base.copy(outboxMaxEventsPerMinute = 300))
        advanceTimeBy(200)
        h.save(base.copy(outboxMaxEventsPerMinute = 400))
        advanceUntilIdle()
        assertEquals(2, h.restartStarts.size)
        val firstFinished = h.restartStarts[0] + RESTART_MS
        assertTrue(
            "follow-up at ${h.restartStarts[1]} broke the minimum gap",
            h.restartStarts[1] >= firstFinished + GAP,
        )
        assertEquals(400, h.restartedOnto.last().outboxMaxEventsPerMinute)
    }

    @Test
    fun `a restart does not trigger another one`() = runTest {
        val h = Harness(this)
        h.save(base.copy(logLevel = "debug"))
        advanceUntilIdle()
        // Saving the same config again (e.g. a screen re-saving on exit).
        h.save(h.disk)
        advanceUntilIdle()
        assertEquals(1, h.restartStarts.size)
        assertFalse(h.applier.isRestarting.value)
    }

    @Test
    fun `changing a value and changing it back restarts nothing`() = runTest {
        val h = Harness(this)
        h.save(base.copy(chatRelayMinFollowers = 9))
        advanceTimeBy(1_000)
        h.save(base)
        advanceUntilIdle()
        assertTrue(h.restartStarts.isEmpty())
    }

    @Test
    fun `a relay that is not running is not restarted`() = runTest {
        val h = Harness(this)
        h.running = null
        h.save(base.copy(relayPort = 4000))
        advanceUntilIdle()
        assertTrue(h.restartStarts.isEmpty())
    }

    @Test
    fun `cancelling ends the wait without restarting`() = runTest {
        val applierScope = CoroutineScope(coroutineContext + Job())
        val h = Harness(this, applierScope)
        h.save(base.copy(relayPort = 4000))
        advanceTimeBy(1_000)
        applierScope.cancel()
        advanceUntilIdle()  // a loop that spun on cancellation would never idle
        assertTrue(h.restartStarts.isEmpty())
        assertFalse(h.applier.isRestarting.value)
    }

    private companion object {
        const val QUIET = RelayConfigApplier.QUIET_PERIOD_MS
        const val GAP = RelayConfigApplier.MINIMUM_GAP_MS
        const val RESTART_MS = 4_000L
    }
}
