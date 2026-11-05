package com.nostrvault.service

import com.nostrvault.relay.RelayDrainState
import kotlinx.coroutines.delay

/**
 * Runs a Go backup or restore once the stopped relay has really let go of
 * the databases ([RelayImportService.withRelayStopped]).
 *
 * Go refuses one (code 1) while the last relay run is still shutting down,
 * and it waits only 10 s for that itself. On a fresh vault the shutdown took
 * over 25 s, and on Logen's Moto 3:10 (2026-11-05), so a fixed or capped
 * wait fails the export. This asks Go whether the old run is still draining
 * ([RelayDrainState]) and waits for as long as that takes, saying so on
 * screen, then runs [op], retrying a refusal a few times. A code that a
 * retry can't change (restoreOwnBackup's 2, not this vault's backup) is
 * returned at once.
 */
internal object ExclusiveDbOp {
    const val ATTEMPTS = 4
    const val RETRY_GAP_MS = 2_500L
    const val POLL_MS = 500L
    const val STOPPING_LINE = "Stopping your vault…"

    suspend fun run(
        op: () -> Int,
        onStatus: (String) -> Unit = {},
        /** Go's refusal while the relay is still up or draining is 1; anything else is the op's own answer. */
        retryable: (Int) -> Boolean = { it == 1 },
        isDraining: () -> Boolean = { RelayDrainState.isDraining },
        pause: suspend (Long) -> Unit = { delay(it) },
    ): Int {
        var code = 1
        for (attempt in 1..ATTEMPTS) {
            if (isDraining()) {
                onStatus(STOPPING_LINE)
                while (isDraining()) pause(POLL_MS)
            }
            code = op()
            if (code == 0 || !retryable(code) || attempt == ATTEMPTS) return code
            pause(RETRY_GAP_MS)
        }
        return code
    }
}
