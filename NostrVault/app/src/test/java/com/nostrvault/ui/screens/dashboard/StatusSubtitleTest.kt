package com.nostrvault.ui.screens.dashboard

import com.nostrvault.ui.screens.dashboard.VaultDashboardModel.RunState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The status card's second line, as on iOS `VaultDashboardView.statusSubtitle`. */
class StatusSubtitleTest {

    private fun line(
        runState: RunState = RunState.RUNNING,
        isExternal: Boolean = false,
        importStatus: String = "",
        bootStatus: String = "",
        wotSyncing: Boolean = false,
        uptime: String? = "Up 2h 5m",
        connections: Int = 3,
    ) = statusSubtitle(runState, isExternal, importStatus, bootStatus, wotSyncing, uptime, connections)

    @Test fun runningShowsUptimeAndConnections() {
        assertEquals("Up 2h 5m · 3 connections", line())
        assertEquals("Up 2h 5m · 1 connection", line(connections = 1))
        assertEquals("Up 2h 5m · 0 connections", line(connections = 0))
    }

    @Test fun runningWithoutAStartTimeStillCountsConnections() {
        assertEquals("2 connections", line(uptime = null, connections = 2))
    }

    @Test fun buildingTheTrustListSaysSo() {
        assertEquals("Updating who can reach you…", line(wotSyncing = true))
    }

    @Test fun startingShowsTheBootStep() {
        assertEquals("Securing feed for 120 trusted users", line(RunState.STARTING, bootStatus = "Securing feed for 120 trusted users"))
        assertNull(line(RunState.STARTING, bootStatus = ""))
    }

    @Test fun importAndExternalKeepTheirLines() {
        assertEquals("Importing your notes…", line(RunState.IMPORTING))
        assertEquals("notes from Mar 2024", line(RunState.IMPORTING, importStatus = "notes from Mar 2024"))
        assertEquals("On your external relay", line(isExternal = true, wotSyncing = true))
    }

    @Test fun pausedAndNeedsFixHaveNone() {
        assertNull(line(RunState.PAUSED))
        assertNull(line(RunState.NEEDS_FIX))
    }
}
