package com.nostrvault.ui.screens.profile

import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.withTimeoutOrNull

/**
 * One page of older notes (or tagged notes) in flight. It finishes when the
 * relays answer, not on a fixed wait: as soon as a relay's EOSE comes with
 * new notes in, or once the relays have answered and gone quiet. "Nothing
 * older left" comes only from relays that answered with nothing new; a page
 * that no relay answers in time just ends, so paging can try again.
 */
class ProfileOlderPage(val tagged: Boolean) {
    enum class Outcome {
        /** New notes came in. */
        GREW,
        /** Relays answered (EOSE) with nothing new: nothing older is left. */
        EMPTY,
        /** No relay answered in time. Says nothing about what is older. */
        TIMED_OUT,
    }

    private val signals = Channel<Boolean>(Channel.UNLIMITED)

    /** Feed every EOSE the stream reports; only this page's kind counts. */
    fun onEose(subId: String) {
        val mine = if (tagged) subId.startsWith(TAGGED_PREFIX)
        else subId.startsWith(NOTES_PREFIX) && !subId.startsWith(TAGGED_PREFIX)
        if (mine) signals.trySend(true)
    }

    /** A note arrived (it may or may not have grown the list). */
    fun onArrival() {
        signals.trySend(false)
    }

    /**
     * Waits for the answer. [size] reads the list this page fills; [before]
     * is its size when the page was asked for. Up to [timeoutMs] for the
     * first EOSE, then [settleMs] of quiet for slower relays to answer too.
     */
    suspend fun await(
        before: Int,
        size: () -> Int,
        timeoutMs: Long = TIMEOUT_MS,
        settleMs: Long = SETTLE_MS,
    ): Outcome {
        val grew = { size() > before }
        // Up to the timeout for the first relay to finish this page.
        val answered = withTimeoutOrNull(timeoutMs) {
            while (!signals.receive()) Unit
        } != null
        if (!answered) return if (grew()) Outcome.GREW else Outcome.TIMED_OUT
        // The page is in: a relay finished and brought new notes.
        if (grew()) return Outcome.GREW
        // A relay finished empty. Give the others a moment: each note or EOSE
        // restarts the wait, and new notes end it at once. Bounded by the
        // timeout too, so a stream of repeats can't hold it open.
        withTimeoutOrNull(timeoutMs) {
            while (withTimeoutOrNull(settleMs) { signals.receive() } != null) {
                if (grew()) return@withTimeoutOrNull
            }
        }
        return if (grew()) Outcome.GREW else Outcome.EMPTY
    }

    companion object {
        const val NOTES_PREFIX = "older-"
        const val TAGGED_PREFIX = "older-tagged-"
        const val TIMEOUT_MS = 10_000L
        const val SETTLE_MS = 1_500L
    }
}
