package com.nostrvault.service

import com.nostrvault.relay.RelayDrainState
import kotlinx.coroutines.delay

/**
 * Runs a Go backup or restore once the stopped relay has really let go of
 * the databases ([RelayImportService.withRelayStopped]).
 *
 * Go refuses one (code 1) while the last relay run is still shutting down,
 * and it waits only 10 s for that itself. On a fresh vault, or offline, the
 * shutdown took over 25 s: the first notes export after a vault restart
 * failed and left an empty zip, and the first restore failed with nothing
 * on screen (day-end test, 2026-11-05). So this asks Go whether the old run
 * is still draining ([RelayDrainState]), waits for it with a line on screen,
 * and only then runs [op], retrying a refusal a few times. A code that a
 * retry can't change (restoreOwnBackup's 2, not this vault's backup) is
 * returned at once.
 */
internal object ExclusiveDbOp {
    const val ATTEMPTS = 4
    const val RETRY_GAP_MS = 2_500L
    const val WAIT_LINE = "Waiting for the vault to finish stopping…"

    /** The old run never finished shutting down within [RelayDrainState.MAX_WAIT_MS]: nothing was run. */
    const val DRAIN_TIMEOUT_CODE = -3
    const val DRAIN_TIMEOUT_LINE = "The vault is still shutting down. Try again in a minute."

    suspend fun run(
        op: () -> Int,
        onStatus: (String) -> Unit = {},
        /** Go's refusal while the relay is still up or draining is 1; anything else is the op's own answer. */
        retryable: (Int) -> Boolean = { it == 1 },
        isDraining: () -> Boolean = { RelayDrainState.isDraining },
        awaitDrained: suspend () -> RelayDrainState.Wait = { RelayDrainState.awaitDrained() },
        pause: suspend (Long) -> Unit = { delay(it) },
    ): Int {
        var code = 1
        for (attempt in 1..ATTEMPTS) {
            if (isDraining()) {
                onStatus(WAIT_LINE)
                if (awaitDrained() != RelayDrainState.Wait.DRAINED) return DRAIN_TIMEOUT_CODE
            }
            code = op()
            if (code == 0 || !retryable(code) || attempt == ATTEMPTS) return code
            pause(RETRY_GAP_MS)
        }
        return code
    }
}
