package com.nostrvault.relay

import android.app.ApplicationExitInfo
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EngineStartGuardTest {
    private fun holds(unfinished: Int, byHand: Boolean = false, counted: Boolean = false) =
        EngineStartGuard.holdsStart(unfinished, byHand, counted)

    @Test fun `a clean history and one bad start both start the vault`() {
        assertFalse(holds(0))
        assertFalse(holds(1))
    }

    @Test fun `two starts in a row that never settled leave the vault off`() {
        assertTrue(holds(EngineStartGuard.MAX_UNFINISHED))
        assertTrue(holds(EngineStartGuard.MAX_UNFINISHED + 3))
    }

    @Test fun `a start by hand always goes through`() {
        assertFalse(holds(EngineStartGuard.MAX_UNFINISHED, byHand = true))
        assertFalse(holds(9, byHand = true))
    }

    @Test fun `a second start call during this run's own boot does not stop it`() {
        // One crash before, then this run counted its start: 2 on disk, engine booting fine.
        assertFalse(holds(EngineStartGuard.MAX_UNFINISHED, counted = true))
    }

    @Test fun `a swipe away, a force stop and an update are not crashes`() {
        assertTrue(EngineStartGuard.notACrash(ApplicationExitInfo.REASON_USER_REQUESTED))
        assertTrue(EngineStartGuard.notACrash(ApplicationExitInfo.REASON_USER_STOPPED))
        assertTrue(EngineStartGuard.notACrash(ApplicationExitInfo.REASON_PACKAGE_UPDATED))
    }

    @Test fun `a low-memory kill, a crash and an unknown exit stay counted`() {
        assertFalse(EngineStartGuard.notACrash(ApplicationExitInfo.REASON_LOW_MEMORY))
        assertFalse(EngineStartGuard.notACrash(ApplicationExitInfo.REASON_CRASH))
        assertFalse(EngineStartGuard.notACrash(ApplicationExitInfo.REASON_CRASH_NATIVE))
        assertFalse(EngineStartGuard.notACrash(ApplicationExitInfo.REASON_SIGNALED))
        assertFalse(EngineStartGuard.notACrash(ApplicationExitInfo.REASON_UNKNOWN))
    }
}
