package com.nostrvault.ui.screens.profile

import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.withTimeoutOrNull

/**
 * One page of older notes (or tagged notes) in flight. It finishes when the
 * relays answer, not on a fixed wait: as soon as one of its relays sends EOSE
 * with new notes in, or once every relay it asked has sent EOSE. "Nothing
 * older left" comes only from all of them answering with nothing new; a page
 * that isn't fully answered in time just ends, so paging can try again.
 */
class ProfileOlderPage {
    enum class Outcome {
        /** New notes came in. */
        GREW,
        /** Every relay asked answered (EOSE) with nothing new: nothing older is left. */
        EMPTY,
        /** Not every relay answered in time. Says nothing about what is older. */
        TIMED_OUT,
    }

    /** An EOSE's subId, or null for a note arriving. */
    private val signals = Channel<String?>(Channel.UNLIMITED)

    /** Feed every EOSE the stream reports; only this page's own subId counts. */
    fun onEose(subId: String) {
        signals.trySend(subId)
    }

    /** A note arrived (it may or may not have grown the list). */
    fun onArrival() {
        signals.trySend(null)
    }

    /**
     * Waits for the answer to the REQ [subId], sent to [relays] relays.
     * [size] reads the list this page fills; [before] is its size when the
     * page was asked for. Up to [timeoutMs] in all.
     */
    suspend fun await(
        subId: String,
        relays: Int,
        before: Int,
        size: () -> Int,
        timeoutMs: Long = TIMEOUT_MS,
    ): Outcome {
        // No relay took the REQ, so nothing can answer it.
        if (relays <= 0) return Outcome.TIMED_OUT
        val grew = { size() > before }
        var answered = 0
        withTimeoutOrNull(timeoutMs) {
            while (answered < relays) {
                if (signals.receive() == subId) answered++
                // A relay has finished this page and notes are in: done. A
                // relay that answered empty never ends the page by itself.
                if (answered > 0 && grew()) return@withTimeoutOrNull
            }
        }
        return when {
            grew() -> Outcome.GREW
            answered >= relays -> Outcome.EMPTY
            else -> Outcome.TIMED_OUT
        }
    }

    companion object {
        const val TIMEOUT_MS = 10_000L
    }
}
