package com.nostrvault.relay

import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * Restarts the embedded relay after a config save, and only when the save
 * changed something the relay reads at start ([RelayConfiguration.LaunchInputs]).
 * Theme, feed relays, blocked accounts and other app-side settings never
 * restart it. Port of iOS RelayProcessManager.applySavedConfig (#92, #97).
 *
 * Saves coalesce. A restart waits until relay-facing saves have been quiet for
 * [quietPeriodMs] (so a value changed in steps restarts the relay once, not
 * per step) and until [minimumGapMs] has passed since the previous settings
 * restart (rapid stop/start cycling is what corrupts BadgerDB), then applies
 * only the latest config. Saves that land during a restart fold into at most
 * one follow-up restart. Cancelling [scope] ends the loop without restarting.
 *
 * Pure apart from its injected hooks, so the timing is unit-tested on virtual
 * time (RelayConfigApplierTest).
 *
 * @param now monotonic clock in milliseconds.
 * @param launchedInputs what the running relay started with, or null when no
 *   embedded relay is up (stopped, importing, external mode). A null relay
 *   needs no restart: its next start reads the saved config from disk.
 * @param inputsFor the launch inputs a config would start the relay with.
 * @param restart restarts the relay onto the saved config and returns when it
 *   has finished (or given up).
 */
class RelayConfigApplier(
    private val scope: CoroutineScope,
    private val now: () -> Long,
    private val launchedInputs: () -> RelayConfiguration.LaunchInputs?,
    private val inputsFor: (HavenConfig) -> RelayConfiguration.LaunchInputs,
    private val restart: suspend () -> Unit,
    private val quietPeriodMs: Long = QUIET_PERIOD_MS,
    private val minimumGapMs: Long = MINIMUM_GAP_MS,
) {
    companion object {
        /** Saves must stop arriving this long before a restart. */
        const val QUIET_PERIOD_MS = 3_000L
        /** Minimum time from the end of one settings restart to the next. */
        const val MINIMUM_GAP_MS = 10_000L
    }

    private val lock = Any()
    private var pending: HavenConfig? = null
    private var pendingInputs: RelayConfiguration.LaunchInputs? = null
    private var lastRequestAt = 0L
    private var lastRestartFinishedAt: Long? = null
    private var job: Job? = null

    private val _isRestarting = MutableStateFlow(false)
    /** True while a save is restarting the relay onto a new config. */
    val isRestarting: StateFlow<Boolean> = _isRestarting.asStateFlow()

    /** Whether the running relay would start differently from [config]. */
    fun needsRestart(config: HavenConfig): Boolean {
        val running = launchedInputs() ?: return false
        return inputsFor(config) != running
    }

    /** Call after [config] has been written to disk. */
    fun configSaved(config: HavenConfig) {
        val running = launchedInputs()
        // No relay up and nothing waiting: its next start reads the disk.
        if (running == null && synchronized(lock) { pending == null }) return
        val inputs = inputsFor(config)
        synchronized(lock) {
            if (pending == null) {
                // Nothing waiting: a save that leaves the relay's start
                // unchanged is not a relay edit and must not start a wait.
                if (running == null || inputs == running) return
                lastRequestAt = now()
            } else if (inputs != pendingInputs) {
                // Only relay-facing edits extend the quiet period; an
                // app-side save landing meanwhile must not starve it.
                lastRequestAt = now()
            }
            pending = config
            pendingInputs = inputs
            if (job != null) return
            val newJob = scope.launch(start = CoroutineStart.LAZY) { drain() }
            job = newJob
            newJob.start()
        }
    }

    private suspend fun drain() {
        val self = currentCoroutineContext()[Job]
        try {
            while (true) {
                // Wait until saves have gone quiet and the relay has had its
                // minimum rest since the last settings restart. delay() throws
                // on cancellation, so a cancelled scope ends here.
                while (true) {
                    val wait = synchronized(lock) {
                        val t = now()
                        val quietLeft = quietPeriodMs - (t - lastRequestAt)
                        val gapLeft = lastRestartFinishedAt?.let { minimumGapMs - (t - it) } ?: 0L
                        maxOf(quietLeft, gapLeft)
                    }
                    if (wait <= 0) break
                    delay(wait)
                }
                val next = synchronized(lock) {
                    val p = pending
                    if (p == null) {
                        // Cleared under the lock so a save racing this exit
                        // starts a new loop instead of being dropped.
                        job = null
                        return
                    }
                    pending = null
                    pendingInputs = null
                    p
                }
                if (!needsRestart(next)) continue
                _isRestarting.value = true
                try {
                    restart()
                } finally {
                    synchronized(lock) { lastRestartFinishedAt = now() }
                    _isRestarting.value = false
                }
            }
        } finally {
            synchronized(lock) { if (job === self) job = null }
        }
    }
}
