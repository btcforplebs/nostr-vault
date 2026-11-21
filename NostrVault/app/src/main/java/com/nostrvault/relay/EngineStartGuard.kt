package com.nostrvault.relay

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.os.Process
import android.util.Log
import com.nostrvault.relay.RelayForegroundService.Companion.PREFS_NAME
import com.nostrvault.relay.RelayForegroundService.Companion.TAG
import com.nostrvault.relay.RelayForegroundService.Companion._startHeld
import com.nostrvault.relay.RelayForegroundService.LifecycleState
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Stops a vault that dies while starting from taking the app with it on every
 * open.
 *
 * The Go engine runs inside the app's process, so a Go fatal error (out of
 * memory, a failed map on a 32-bit phone) ends the whole app, and opening the
 * app starts the engine again at once. Whatever made it die is still on disk,
 * so the app died on every open until its data was cleared (a 2 GB Samsung,
 * 2026-11-21). [WatchdogRestartPolicy] limits the restarts the system makes;
 * nothing limited the ones a person makes by opening the app.
 *
 * So each engine start is counted in prefs before it runs, and the count is
 * cleared once the engine has stayed up for [SETTLED_AFTER_MS] (or stopped or
 * gave up without the process dying). A count left at [MAX_UNFINISHED] means
 * that many starts in a row ended with the process gone: the next open leaves
 * the vault off and says so, and the app is usable. Start, tapped by a person,
 * clears the count and tries again.
 *
 * What it does not catch: a death after the engine has been up for
 * [SETTLED_AFTER_MS] (a first sync or a full feed that runs memory out later).
 * That start has settled, so nothing is counted and the next open starts the
 * engine as before.
 *
 * A process that Android says ended because a person or an update ended it
 * (swiped away, force stopped, app updated) is not a crash and is taken back
 * off the count ([notACrash], Android 11 and later). A low-memory kill stays
 * counted: on a small phone that is the failure itself.
 */
object EngineStartGuard {
    /** Starts in a row that never settled before the vault is left off. */
    const val MAX_UNFINISHED = 2
    /** How long the engine must stay up for its start to count as fine. */
    const val SETTLED_AFTER_MS = 30_000L
    internal const val PREF_UNFINISHED_STARTS = "unfinished_engine_starts"
    internal const val PREF_COUNTED_PID = "unfinished_engine_start_pid"
    internal const val PREF_COUNTED_AT = "unfinished_engine_start_at"
    internal const val EXTRA_BY_HAND = "com.nostrvault.relay.START_BY_HAND"

    /**
     * Whether an exit [reason] (ApplicationExitInfo) means the app did not
     * crash: a person or an update ended it. Everything else, a low-memory
     * kill and an unknown reason included, counts.
     */
    fun notACrash(reason: Int): Boolean =
        reason == ApplicationExitInfo.REASON_USER_REQUESTED ||
            reason == ApplicationExitInfo.REASON_USER_STOPPED ||
            reason == ApplicationExitInfo.REASON_PACKAGE_UPDATED

    /**
     * Whether a start is refused. Never one a person asked for ([byHand]), and
     * never while this process's own start is the one being counted
     * ([countedThisRun]): a second start() call during a boot that is going
     * fine must not stop it.
     */
    fun holdsStart(unfinishedStarts: Int, byHand: Boolean, countedThisRun: Boolean): Boolean =
        !byHand && !countedThisRun && unfinishedStarts >= MAX_UNFINISHED

    /** True while this process has a start counted and not yet cleared. */
    @Volatile internal var countedThisRun = false
}

private fun RelayForegroundService.guardPrefs() = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

/** Asked at each start: true when the vault stays off. A start by hand clears the count first. */
internal fun RelayForegroundService.engineStartHeld(byHand: Boolean): Boolean {
    if (byHand) clearEngineStartCount() else forgiveExitThatWasNoCrash()
    val unfinished = guardPrefs().getInt(EngineStartGuard.PREF_UNFINISHED_STARTS, 0)
    val held = EngineStartGuard.holdsStart(unfinished, byHand, EngineStartGuard.countedThisRun)
    _startHeld.value = held
    return held
}

/**
 * Counts the engine start that is about to run, once per run. commit(), not
 * apply(): the process may be gone a moment later, and the count has to be
 * on disk by then.
 */
internal fun RelayForegroundService.countEngineStart() {
    if (EngineStartGuard.countedThisRun) return
    EngineStartGuard.countedThisRun = true
    val prefs = guardPrefs()
    val n = prefs.getInt(EngineStartGuard.PREF_UNFINISHED_STARTS, 0) + 1
    prefs.edit()
        .putInt(EngineStartGuard.PREF_UNFINISHED_STARTS, n)
        .putInt(EngineStartGuard.PREF_COUNTED_PID, Process.myPid())
        .putLong(EngineStartGuard.PREF_COUNTED_AT, System.currentTimeMillis())
        .commit()
    Log.i(TAG, "Engine start counted ($n not yet settled)")
}

/**
 * Takes the last counted start back off the count when Android says the
 * process that counted it was ended by a person or an update, not by a crash.
 * Looked up by that process's pid, and only an exit after the count was
 * written, so a reused pid or an older run is never mistaken for it. Once per
 * counted start: the pid is forgotten as soon as it has been forgiven.
 */
internal fun RelayForegroundService.forgiveExitThatWasNoCrash() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R || EngineStartGuard.countedThisRun) return
    val prefs = guardPrefs()
    val n = prefs.getInt(EngineStartGuard.PREF_UNFINISHED_STARTS, 0)
    val pid = prefs.getInt(EngineStartGuard.PREF_COUNTED_PID, 0)
    if (n <= 0 || pid == 0) return
    val exit = runCatching {
        getSystemService(ActivityManager::class.java)
            ?.getHistoricalProcessExitReasons(packageName, pid, 1)?.firstOrNull()
    }.getOrNull() ?: return
    if (exit.timestamp < prefs.getLong(EngineStartGuard.PREF_COUNTED_AT, 0L)) return
    if (!EngineStartGuard.notACrash(exit.reason)) return
    prefs.edit()
        .putInt(EngineStartGuard.PREF_UNFINISHED_STARTS, n - 1)
        .remove(EngineStartGuard.PREF_COUNTED_PID)
        .remove(EngineStartGuard.PREF_COUNTED_AT)
        .commit()
    Log.i(TAG, "Last start ended by a person or an update (reason ${exit.reason}); not counted")
}

/** The start ended without the process dying: nothing is counted against the next one. */
internal fun RelayForegroundService.clearEngineStartCount() {
    EngineStartGuard.countedThisRun = false
    guardPrefs().edit()
        .remove(EngineStartGuard.PREF_UNFINISHED_STARTS)
        .remove(EngineStartGuard.PREF_COUNTED_PID)
        .remove(EngineStartGuard.PREF_COUNTED_AT)
        .commit()
    _startHeld.value = false
}

/** Called when the engine is up: clears the count if it is still up [EngineStartGuard.SETTLED_AFTER_MS] later. */
internal fun RelayForegroundService.settleEngineStartLater() {
    serviceScope.launch {
        delay(EngineStartGuard.SETTLED_AFTER_MS)
        if (lifecycleState == LifecycleState.RUNNING) clearEngineStartCount()
    }
}
