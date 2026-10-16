package com.nostrvault.ui.components

/** Refresh: follows, web, pictures. */
internal const val REFRESH_STEPS = 3
/** How long refresh waits for the trust graph to be read off disk. */
internal const val TRUST_GRAPH_WAIT_MS = 1_500L
/** The full bar holds this long before it fades, so the end reads as done. */
internal const val REFRESH_DONE_HOLD_MS = 700L
/** A refresh that didn't save a new web holds its reason this long. */
internal const val REFRESH_FAILED_HOLD_MS = 3_500L
/** "Relay isn't running" stays up this long before refresh goes on. */
internal const val RELAY_DOWN_HOLD_MS = 1_500L
/** The relay's rebuild is polled this often, at most [MAX_WOT_POLLS] times (6 minutes). */
internal const val WOT_POLL_MS = 500L
internal const val MAX_WOT_POLLS = 720

/**
 * The WOT tab checks on the relay's rebuild this often while one runs, and
 * this often while none does. Every few seconds either way: newcomers arrive
 * in batches, and each check that finds some wakes the globe. iOS 61879988.
 */
internal const val LIVE_POLL_MS = 5_000L
internal const val IDLE_POLL_MS = 5_000L

/**
 * Where a refresh is: [fill] out of [REFRESH_STEPS], and what it's doing.
 * [failed] once a finished run didn't save a new web.
 */
internal data class RefreshState(val fill: Float, val caption: String, val failed: Boolean = false) {
    val done: Boolean get() = fill >= REFRESH_STEPS
}
