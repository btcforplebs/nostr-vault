package com.nostrvault.relay

import kotlinx.coroutines.delay

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
 * Go answers this itself (RelayDrainingC). The relay log is no source for
 * it: it carries remote text (reaction content, relay NOTICEs), and a
 * newline in that text forges a whole log line. While [isDraining] is true,
 * nothing deletes the Badger LOCK files (they belong to databases that are
 * still open) and the service waits for the drain instead of counting
 * failed starts, up to [MAX_WAIT_MS].
 */
object RelayDrainState {
    /**
     * The longest the service waits for a drain before it leaves the relay
     * offline. A straggler that never ends (a frozen socket) would otherwise
     * hold the service in STOPPING or BOOTING for good.
     */
    internal const val MAX_WAIT_MS = 3 * 60_000L

    /** How a wait for the drain ended. */
    enum class Wait { DRAINED, STOPPED, TIMED_OUT }

    /** Asks Go; replaced in tests, where there is no native library. */
    internal var probe: () -> Boolean = {
        HavenBridge.isLoaded && runCatching { HavenBridge.relayDraining() }.getOrDefault(false)
    }

    val isDraining: Boolean get() = probe()

    /**
     * Waits until the old run has shut down, checking [stop] between polls,
     * for at most [maxMs].
     */
    suspend fun awaitDrained(
        pollMs: Long = 500L,
        maxMs: Long = MAX_WAIT_MS,
        stop: () -> Boolean = { false },
    ): Wait {
        val deadline = System.currentTimeMillis() + maxMs
        while (isDraining) {
            if (stop()) return Wait.STOPPED
            if (System.currentTimeMillis() >= deadline) return Wait.TIMED_OUT
            delay(pollMs)
        }
        return Wait.DRAINED
    }

    /**
     * If the last run is still shutting down, waits for it like
     * [awaitDrained]; returns null at once otherwise.
     */
    suspend fun awaitDrainedIfDraining(
        pollMs: Long = 500L,
        maxMs: Long = MAX_WAIT_MS,
        stop: () -> Boolean = { false },
    ): Wait? = if (isDraining) awaitDrained(pollMs, maxMs, stop) else null
}
