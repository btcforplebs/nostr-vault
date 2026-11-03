package com.nostrvault.service

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive

/**
 * NIP-42 on one connection that reads DMs. Port of iOS `DMReadAuth` (#1506).
 *
 * Some DM relays (relay.damus.io, nostr.wine, a Haven inbox) hand gift wraps
 * only to the reader they are addressed to: the REQ is closed with
 * "auth-required: …" until the reader AUTHs. The external DM read only
 * handled EVENT, so whatever a stranger sent only to such a relay never
 * reached Requests (RESEARCH/NV_IOS_MESSAGE_REQUESTS_11_01.md).
 *
 * One AUTH per connection at most, never a loop: a relay that turns the AUTH
 * down, or closes the REQ again after accepting it, is given up on, and the
 * caller remembers that for the rest of the app session ([mayAuth] false), so
 * a remote signer is not asked again on every foreground.
 *
 * Free of Android types so plain unit tests can run it.
 */
class DMReadAuth(val mayAuth: Boolean) {
    sealed class Step {
        data object None : Step()
        /** Sign a kind 22242 for this challenge and hand its id to [authSent]. */
        data class Sign(val challenge: String) : Step()
        /** The AUTH was accepted: send these REQs again. */
        data class Resend(val reqs: List<String>) : Step()
        /** Stop asking this relay for the session. */
        data class GiveUp(val why: String) : Step()
    }

    private sealed class Phase {
        data object Idle : Phase()
        data object Signing : Phase()
        data class Sent(val id: String) : Phase()
        data object Accepted : Phase()
        data object Done : Phase()
    }

    var challenge: String? = null
        private set
    private var phase: Phase = Phase.Idle
    private val reqs = HashMap<String, String>() // sub id -> REQ text
    private val waiting = ArrayList<String>() // sub ids closed for auth, in order

    /** True while an AUTH is being signed or answered: keep the connection open a little longer. */
    val isAuthenticating: Boolean
        get() = phase == Phase.Signing || phase is Phase.Sent

    /**
     * A REQ was closed for auth and no challenge has come yet. Some relays send
     * CLOSED before their AUTH challenge: the read isn't over, the challenge is
     * still on its way (the caller's timer ends the wait).
     */
    val isAwaitingChallenge: Boolean
        get() = mayAuth && phase == Phase.Idle && waiting.isNotEmpty() && challenge == null

    /** Remember a REQ so it can be sent again after the AUTH. */
    fun sent(subId: String, req: String) {
        reqs[subId] = req
    }

    /** Feed every non-EVENT frame from the relay through here. */
    fun receive(frame: JsonArray): Step {
        val type = frame.str(0) ?: return Step.None
        return when (type) {
            "AUTH" -> {
                val value = frame.str(1)
                if (value.isNullOrEmpty()) return Step.None
                challenge = value
                startIfReady()
            }
            "CLOSED" -> {
                val subId = frame.str(1)
                if (subId == null || subId !in reqs) return Step.None
                val reason = frame.str(2) ?: ""
                if (!reason.startsWith("auth-required")) return Step.None
                when (phase) {
                    // Closed again after the relay let us in: AUTH can't help here.
                    Phase.Accepted -> {
                        phase = Phase.Done
                        Step.GiveUp("still closed after AUTH: $reason")
                    }
                    Phase.Done -> Step.None
                    else -> {
                        if (subId !in waiting) waiting.add(subId)
                        startIfReady()
                    }
                }
            }
            "OK" -> {
                val sent = phase as? Phase.Sent ?: return Step.None
                if (frame.str(1) != sent.id) return Step.None
                val accepted = runCatching { frame[2].jsonPrimitive.booleanOrNull }.getOrNull() ?: false
                if (!accepted) {
                    phase = Phase.Done
                    return Step.GiveUp("AUTH refused: ${frame.str(3) ?: ""}")
                }
                phase = Phase.Accepted
                val again = waiting.mapNotNull { reqs[it] }
                waiting.clear()
                Step.Resend(again)
            }
            else -> Step.None
        }
    }

    /** The signed AUTH went to the relay. */
    fun authSent(id: String) {
        if (phase == Phase.Signing) phase = Phase.Sent(id)
    }

    /** The signer didn't sign (declined, timed out, account switched). */
    fun signFailed(): Step {
        if (phase != Phase.Signing) return Step.None
        phase = Phase.Done
        return Step.GiveUp("not signed")
    }

    private fun startIfReady(): Step {
        val ch = challenge
        if (!mayAuth || phase != Phase.Idle || waiting.isEmpty() || ch == null) return Step.None
        phase = Phase.Signing
        return Step.Sign(ch)
    }

    private fun JsonArray.str(i: Int): String? = runCatching { this[i].jsonPrimitive.contentOrNull }.getOrNull()

    companion object {
        /**
         * Where the external DM read looks, in order: your DM inbox relays first
         * (where DMs to you are published), then the rest. Duplicates (any
         * spelling) and loopback dropped, capped at [cap].
         */
        fun fetchRelays(groups: List<List<String>>, cap: Int): List<String> {
            val seen = HashSet<String>()
            val out = ArrayList<String>()
            for (relay in groups.flatten()) {
                if (out.size >= cap) break
                val key = relayKey(relay)
                if (key.isEmpty() || NostrService.isLoopbackRelay(relay) || !seen.add(key)) continue
                out.add(relay.trim())
            }
            return out
        }

        /** One spelling per relay URL, for comparing lists. */
        fun relayKey(relay: String): String = relay.trim().trim('/', ' ').lowercase()

        /**
         * Relays whose DM-read AUTH failed this app session ("account|relay key"):
         * refused, closed again after AUTH, or the signer didn't sign. They are
         * read without AUTH from then on, so a remote signer is asked at most once
         * per relay per connection and never again after a failure.
         */
        private val givenUp = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()

        fun mayAuth(account: String, relay: String): Boolean =
            account.isNotEmpty() && "$account|${relayKey(relay)}" !in givenUp

        fun giveUp(account: String, relay: String) {
            givenUp.add("$account|${relayKey(relay)}")
        }

        internal fun resetForTests() = givenUp.clear()
    }
}

/** One DM-reading connection's NIP-42 state, shared by its collector, signer and timers. */
class DMReadAuthLink(val url: String, val account: String, mayAuth: Boolean, private val clock: () -> Long = System::currentTimeMillis) {
    private val state = DMReadAuth(mayAuth)
    private var resentAt = 0L
    private var extended = false

    @Synchronized fun sent(subId: String, req: String) = state.sent(subId, req)
    @Synchronized fun receive(frame: JsonArray): DMReadAuth.Step = state.receive(frame)
    @Synchronized fun authSent(id: String) = state.authSent(id)
    @Synchronized fun signFailed(): DMReadAuth.Step = state.signFailed()
    @Synchronized fun markResent() { resentAt = clock() }

    val isAuthenticating: Boolean @Synchronized get() = state.isAuthenticating
    val isAwaitingChallenge: Boolean @Synchronized get() = state.isAwaitingChallenge
    val resentRecently: Boolean @Synchronized get() = resentAt > 0 && clock() - resentAt < 8_000

    /**
     * True once, when an AUTH is under way or its re-sent REQ was just sent:
     * the caller keeps the connection open a little longer (a remote signer
     * signs over its own relay, and the re-sent REQ still has to be answered).
     */
    @Synchronized fun mayExtend(): Boolean {
        if (extended || !(state.isAuthenticating || (resentAt > 0 && clock() - resentAt < 8_000))) return false
        extended = true
        return true
    }
}
