package com.nostrvault.relay

/**
 * How often the health watchdog may restart the relay by itself.
 *
 * Every restart starts the relay's syncs over, which can pull hundreds of MB.
 * A relay that died again and again was restarted every ~90 s with no limit, so
 * the watchdog now waits longer before each restart in a [WINDOW_MS] window
 * and gives up after [MAX_RESTARTS] of them: the relay shows Offline and waits
 * for someone to open the app or tap Start (which clears the count).
 */
object WatchdogRestartPolicy {
    const val WINDOW_MS = 6 * 60 * 60 * 1000L
    const val MAX_RESTARTS = 4
    /** The wait before the 1st, 2nd, 3rd and 4th restart in a window. */
    private val WAITS_MS = longArrayOf(0L, 60_000L, 5 * 60_000L, 20 * 60_000L)

    /**
     * The wait before the next restart, or null to give up. [restartsAtMs] are
     * the earlier restarts' times; ones older than the window no longer count.
     */
    fun waitBeforeRestart(restartsAtMs: List<Long>, nowMs: Long): Long? {
        val recent = restartsAtMs.count { nowMs - it < WINDOW_MS }
        if (recent >= MAX_RESTARTS) return null
        return WAITS_MS[recent.coerceAtMost(WAITS_MS.size - 1)]
    }
}
