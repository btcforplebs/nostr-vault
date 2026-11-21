package com.nostrvault.relay

import android.content.Context
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
 */
object EngineStartGuard {
    /** Starts in a row that never settled before the vault is left off. */
    const val MAX_UNFINISHED = 2
    /** How long the engine must stay up for its start to count as fine. */
    const val SETTLED_AFTER_MS = 30_000L
    internal const val PREF_UNFINISHED_STARTS = "unfinished_engine_starts"
    internal const val EXTRA_BY_HAND = "com.nostrvault.relay.START_BY_HAND"

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
    if (byHand) clearEngineStartCount()
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
    prefs.edit().putInt(EngineStartGuard.PREF_UNFINISHED_STARTS, n).commit()
    Log.i(TAG, "Engine start counted ($n not yet settled)")
}

/** The start ended without the process dying: nothing is counted against the next one. */
internal fun RelayForegroundService.clearEngineStartCount() {
    EngineStartGuard.countedThisRun = false
    guardPrefs().edit().remove(EngineStartGuard.PREF_UNFINISHED_STARTS).commit()
    _startHeld.value = false
}

/** Called when the engine is up: clears the count if it is still up [EngineStartGuard.SETTLED_AFTER_MS] later. */
internal fun RelayForegroundService.settleEngineStartLater() {
    serviceScope.launch {
        delay(EngineStartGuard.SETTLED_AFTER_MS)
        if (lifecycleState == LifecycleState.RUNNING) clearEngineStartCount()
    }
}
