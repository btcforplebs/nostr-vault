package com.nostrvault.relay

import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Whether the Go relay's last stopped run is still shutting down.
 *
 * StopRelayC returns after about 2 s even when some of the run's goroutines
 * are still going (a Web of Trust rebuild on a big follow list is the usual
 * one). Their databases stay open until they finish, and until then every
 * StartRelayC is refused: the port never opens and the health check fails.
 * The service retried three times inside about 90 s and then gave up for
 * good, a few seconds before the old run let go (Logen's Moto, 2026-10-30).
 *
 * Go says so only in its log, so [observe] reads the lines [LogStore] polls.
 * While [draining] is true, nothing deletes the Badger LOCK files (they
 * belong to databases that are still open) and the service waits for the
 * drain instead of counting failed starts.
 */
object RelayDrainState {
    // haven-go/cshared.go StopRelayC and haven-go/lifecycle.go errStillDraining.
    internal const val STRAGGLERS_LINE = "databases close when they finish"
    internal const val REFUSED_LINE = "the last relay cycle is still shutting down"
    internal const val DRAINED_LINE = "last relay cycle drained; databases closed"

    /**
     * How long after StopRelayC returns its log line can take to reach
     * [observe]: [LogStore] polls every 200 ms.
     */
    internal const val LOG_SETTLE_MS = 600L

    private val _draining = MutableStateFlow(false)
    val draining: StateFlow<Boolean> = _draining.asStateFlow()

    val isDraining: Boolean get() = _draining.value

    /** Applies one relay log line. */
    fun observe(line: String) {
        when {
            line.contains(DRAINED_LINE) -> _draining.value = false
            line.contains(STRAGGLERS_LINE) || line.contains(REFUSED_LINE) -> _draining.value = true
        }
    }

    /**
     * Waits until the old run has shut down, checking [stop] between polls.
     * Returns false only when [stop] asked to give up.
     */
    suspend fun awaitDrained(pollMs: Long = 500L, stop: () -> Boolean = { false }): Boolean {
        delay(LOG_SETTLE_MS)
        while (_draining.value) {
            if (stop()) return false
            delay(pollMs)
        }
        return true
    }

    /**
     * If the last run is still shutting down, waits for it and returns true
     * (also when [stop] cut the wait short); returns false at once otherwise.
     */
    suspend fun awaitDrainedIfDraining(pollMs: Long = 500L, stop: () -> Boolean = { false }): Boolean {
        if (!_draining.value) return false
        while (_draining.value && !stop()) delay(pollMs)
        return true
    }

    /** The relay answered its health check, so no old run holds the databases. */
    fun markRunning() {
        _draining.value = false
    }

    internal fun resetForTest() {
        _draining.value = false
    }
}
