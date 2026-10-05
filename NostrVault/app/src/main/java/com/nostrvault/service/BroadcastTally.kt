package com.nostrvault.service

/**
 * Turns the per-relay `OK` replies for one broadcast into a single answer:
 * accepted as soon as one relay takes the event, refused only once every
 * relay has answered without taking it (a refusal, a timeout, or no
 * connection). Used to show "Posted" only when the post really landed.
 * Port of BroadcastTally in RelayConfiguration.swift.
 */
class BroadcastTally(val relayCount: Int) {
    enum class Outcome { ACCEPTED, REFUSED }

    private val answered = mutableSetOf<String>()

    var outcome: Outcome? = if (relayCount == 0) Outcome.REFUSED else null
        private set

    /**
     * Records one relay's answer and returns the outcome the first time it
     * is decided, null otherwise. Later answers never change it.
     */
    @Synchronized
    fun record(relay: String, success: Boolean, message: String): Outcome? {
        if (outcome != null || !answered.add(relay)) return null
        // NIP-01: a relay that already holds the event may say so with
        // ok=false. The event is there, which is what the user cares about.
        if (success || message.lowercase().startsWith("duplicate:")) {
            outcome = Outcome.ACCEPTED
            return Outcome.ACCEPTED
        }
        if (answered.size >= relayCount) {
            outcome = Outcome.REFUSED
            return Outcome.REFUSED
        }
        return null
    }
}
