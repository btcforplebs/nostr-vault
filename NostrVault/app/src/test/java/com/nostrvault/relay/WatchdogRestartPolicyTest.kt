package com.nostrvault.relay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class WatchdogRestartPolicyTest {
    private val hour = 60 * 60 * 1000L
    private val now = 100 * hour

    @Test fun `first restart is immediate, later ones wait longer`() {
        assertEquals(0L, WatchdogRestartPolicy.waitBeforeRestart(emptyList(), now))
        assertEquals(60_000L, WatchdogRestartPolicy.waitBeforeRestart(listOf(now - 1), now))
        assertEquals(5 * 60_000L, WatchdogRestartPolicy.waitBeforeRestart(listOf(now - 2, now - 1), now))
        assertEquals(20 * 60_000L, WatchdogRestartPolicy.waitBeforeRestart(listOf(now - 3, now - 2, now - 1), now))
    }

    @Test fun `gives up after four restarts in six hours`() {
        assertNull(WatchdogRestartPolicy.waitBeforeRestart(List(4) { now - it * hour }, now))
    }

    @Test fun `restarts older than six hours no longer count`() {
        val old = List(4) { now - 6 * hour - it }
        assertEquals(0L, WatchdogRestartPolicy.waitBeforeRestart(old, now))
        assertEquals(60_000L, WatchdogRestartPolicy.waitBeforeRestart(old + (now - hour), now))
    }
}
