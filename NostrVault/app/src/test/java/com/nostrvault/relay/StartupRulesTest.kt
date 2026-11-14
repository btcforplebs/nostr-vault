package com.nostrvault.relay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Cold start (Logen 2026-11-14, Vault rows < 0.5 s): when the engine starts and what may hold it back. */
class StartupRulesTest {

    @Test
    fun opensTheAppAgainRightAwayWithoutTheCrashWait() {
        // Swiped away and opened again 5 s later: no wait.
        assertEquals(0L, RelayForegroundService.crashRestartDelay(stickyRestart = false, sinceLastStartMs = 5_000, windowMs = 30_000, delayMs = 3_000))
        // The system restarting a relay that just died still waits.
        assertEquals(3_000L, RelayForegroundService.crashRestartDelay(stickyRestart = true, sinceLastStartMs = 5_000, windowMs = 30_000, delayMs = 3_000))
        assertEquals(0L, RelayForegroundService.crashRestartDelay(stickyRestart = true, sinceLastStartMs = 40_000, windowMs = 30_000, delayMs = 3_000))
        assertEquals(0L, RelayForegroundService.crashRestartDelay(stickyRestart = true, sinceLastStartMs = 0, windowMs = 30_000, delayMs = 3_000))
    }

    @Test
    fun theEngineStartsAtLaunchOnlyWhenTheEmbeddedRelayIsInUse() {
        assertTrue(RelayForegroundService.startsAtLaunch(setupDone = true, externalRelay = false, importing = false))
        assertFalse(RelayForegroundService.startsAtLaunch(setupDone = false, externalRelay = false, importing = false))
        assertFalse(RelayForegroundService.startsAtLaunch(setupDone = true, externalRelay = true, importing = false))
        assertFalse(RelayForegroundService.startsAtLaunch(setupDone = true, externalRelay = false, importing = true))
    }

    @Test
    fun marksHaveTheShapeGoAndTheIPhoneWrite() {
        assertEquals("⏱ startup vault rows shown +412ms", StartupMarks.line("vault rows shown", 412))
    }
}
