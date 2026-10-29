package com.nostrvault.relay

import android.content.Context
import com.nostrvault.relay.RelayForegroundService.Companion.PREFS_NAME
import com.nostrvault.relay.RelayForegroundService.Companion.PREF_LAST_START_TIME
import com.nostrvault.relay.RelayForegroundService.Companion.PREF_WATCHDOG_RESTARTS

// ── Restart count kept in prefs ([WatchdogRestartPolicy]) ──────────
// The list lives in memory for the watchdog and in prefs so a process that
// dies (a Go fatal error, then a START_STICKY restart) does not clear it.

private fun RelayForegroundService.restartPrefs() =
    getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

/** Someone started the relay: the count starts over. */
internal fun RelayForegroundService.clearWatchdogRestarts() {
    synchronized(watchdogRestarts) { watchdogRestarts.clear() }
    restartPrefs().edit().remove(PREF_WATCHDOG_RESTARTS).apply()
}

/** Counts a restart at [nowMs]; returns the wait before it, or null to give up. */
internal fun RelayForegroundService.recordWatchdogRestart(nowMs: Long): Long? =
    synchronized(watchdogRestarts) {
        if (watchdogRestarts.isEmpty()) {
            watchdogRestarts += WatchdogRestartPolicy.decode(restartPrefs().getString(PREF_WATCHDOG_RESTARTS, null))
        }
        WatchdogRestartPolicy.waitBeforeRestart(watchdogRestarts, nowMs)?.also {
            watchdogRestarts.add(nowMs)
            restartPrefs().edit()
                .putString(PREF_WATCHDOG_RESTARTS, WatchdogRestartPolicy.encode(watchdogRestarts, nowMs))
                .apply()
        }
    }

/**
 * A START_STICKY restart. One that comes within [crashWindowMs] of the last
 * start is a crash loop and counts as a restart; any other is a one-off system
 * kill and starts at once. Returns the wait, or null to give up.
 */
internal fun RelayForegroundService.stickyRestartWait(crashWindowMs: Long): Long? {
    val now = System.currentTimeMillis()
    val sinceLastStart = now - restartPrefs().getLong(PREF_LAST_START_TIME, 0)
    if (sinceLastStart !in 1 until crashWindowMs) return 0L
    return recordWatchdogRestart(now)
}
