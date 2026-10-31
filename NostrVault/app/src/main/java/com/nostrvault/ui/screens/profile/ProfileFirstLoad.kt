package com.nostrvault.ui.screens.profile

import com.nostrvault.data.remote.LookupSocketPool

/**
 * When a profile's first load is over, so the spinner can stop.
 *
 * The vault relay answers "nothing" for a stranger in a few milliseconds.
 * Ending on that first EOSE showed an empty profile before any outside relay
 * had replied. So EOSEs only count from the relays that hold this person's
 * posts: their write relays from their kind 10002, or, when no list turns
 * up, [FALLBACK_RELAYS]. The load is over once their relay list is settled
 * (found, or given up on) and every one of those relays has sent EOSE.
 * A relay that never answers is covered by the view model's time caps.
 *
 * Not thread-safe on its own; the view model calls it under its lock.
 */
class ProfileFirstLoad {
    /** Relays whose EOSE the load waits for, keyed by [LookupSocketPool.relayKey]. */
    private val waitingOn = mutableSetOf<String>()
    private val answered = mutableSetOf<String>()
    private var listSettled = false

    /** Their write relays are known; the load waits for them. */
    fun outboxKnown(outbox: List<String>) {
        listSettled = true
        outbox.forEach { waitingOn.add(LookupSocketPool.relayKey(it)) }
    }

    /** No relay list turned up in time; the load waits for the fallback relays instead. */
    fun noOutbox() {
        listSettled = true
        FALLBACK_RELAYS.forEach { waitingOn.add(LookupSocketPool.relayKey(it)) }
    }

    /** [relayUrl] finished the first page. Returns true when the load is over. */
    fun onEose(relayUrl: String): Boolean {
        answered.add(LookupSocketPool.relayKey(relayUrl))
        return isDone()
    }

    fun isDone(): Boolean = listSettled && waitingOn.isNotEmpty() && answered.containsAll(waitingOn)

    companion object {
        /** Asked when someone has no relay list: where most people's posts are. */
        val FALLBACK_RELAYS = listOf(
            "wss://nos.lol",
            "wss://relay.primal.net",
            "wss://relay.snort.social",
        )
        /** How long to wait for their kind 10002 before using [FALLBACK_RELAYS]. */
        const val LIST_WAIT_MS = 6_000L
        /** How long the outbox or fallback relays get to send EOSE once asked. */
        const val EOSE_WAIT_MS = 8_000L
    }
}
