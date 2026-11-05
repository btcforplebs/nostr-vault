package com.nostrvault.service

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull

/**
 * One connection to this device's vault relay at one path, shared by every request to that path while it stays
 * open: it logs in (NIP-42 AUTH) once, then each request rides the logged-in socket. Twin of iOS
 * `VaultSessionCore.swift` (#1739).
 *
 * It used to be a new socket and a new AUTH per request. With Amber or a bunker every AUTH is a round trip to the
 * person's signer: Logen's iPhone sent 2,262 logins to its own vault in three days (LogePhone relay.log, 2026-11-05).
 *
 * Pure (no sockets, no signing): [VaultSocket] feeds it what happens and does what it returns. Send on connect,
 * answer the connection's challenge once, resend a refused request only after the vault's OK for that AUTH; one
 * `auth-required` after the OK gets one retry.
 */
internal class VaultSessionCore {
    enum class Kind { REQ, EVENT }

    sealed interface Outcome {
        /** A REQ's events, up to its EOSE. */
        data class Events(val events: List<JsonObject>) : Outcome
        /** An EVENT's OK: accepted, or already held. */
        data class Accepted(val ok: Boolean) : Outcome
        /** No answer: refused, dropped or timed out. */
        data object Failed : Outcome
    }

    sealed interface Effect {
        data object Connect : Effect
        data object Disconnect : Effect
        data class Send(val frame: String) : Effect
        /** Sign a kind 22242 for this challenge, then call [authSigned] (or [authUnavailable]). */
        data class SignAuth(val challenge: String) : Effect
        data class Finish(val key: String, val outcome: Outcome) : Effect
    }

    enum class Link { DOWN, CONNECTING, UP }

    sealed interface Auth {
        data object None : Auth
        data object Signing : Auth
        data class Sent(val id: String) : Auth
        data object Authed : Auth
    }

    private data class Op(
        val kind: Kind,
        val frame: String,
        val token: Int,
        var sent: Boolean = false,
        /** [heard] when it was last sent. */
        var sentAt: Int = 0,
        var retried: Boolean = false,
        val events: MutableList<JsonObject> = mutableListOf(),
    )

    var link = Link.DOWN
        private set
    var auth: Auth = Auth.None
        private set
    private val ops = LinkedHashMap<String, Op>()
    /** Messages received on this socket, to tell a slow vault from a dead socket. */
    private var heard = 0
    /** Submissions so far: a timer set for an earlier submission of a key can't end a later one. */
    private var submissions = 0

    /** No request waiting: the socket may be closed when it stays so. */
    val isIdle: Boolean get() = ops.isEmpty()

    /**
     * A request: [key] is a REQ's subscription id or an EVENT's id, [frame] the JSON text to send. The same key asked
     * again while the first is out ends the first as [Outcome.Failed].
     */
    fun submit(key: String, kind: Kind, frame: String): Pair<Int, List<Effect>> {
        val out = mutableListOf<Effect>()
        if (ops.containsKey(key)) out += finish(key, Outcome.Failed)
        submissions += 1
        ops[key] = Op(kind, frame, submissions)
        when (link) {
            Link.DOWN -> {
                link = Link.CONNECTING
                out += Effect.Connect
            }
            Link.CONNECTING -> Unit
            Link.UP -> out += sendReady()
        }
        return submissions to out
    }

    fun connected(): List<Effect> {
        link = Link.UP
        // The vault's challenge can be handled before CONNECTED (two collectors): keep that login under way rather
        // than forget it and sign a second time. Every way down already reset auth, so nothing older is kept.
        heard = 0
        return sendReady()
    }

    /** The socket closed or failed: whatever was asked on it gets no answer. The next request opens a new one. */
    fun disconnected(): List<Effect> {
        if (link == Link.DOWN) return emptyList()
        link = Link.DOWN
        auth = Auth.None
        return failAll()
    }

    /** The AUTH for the challenge is signed: send it, and hold every request until the vault's OK for it. */
    fun authSigned(id: String, frame: String): List<Effect> {
        if (auth != Auth.Signing) return emptyList()
        auth = Auth.Sent(id)
        return listOf(Effect.Send(frame))
    }

    /** No AUTH could be signed (no signer session yet): close; the next request tries again. */
    fun authUnavailable(): List<Effect> {
        if (auth != Auth.Signing) return emptyList()
        link = Link.DOWN
        auth = Auth.None
        return listOf(Effect.Disconnect) + failAll()
    }

    /** Gave up waiting for submission [token] of [key]. A timer for an earlier submission does nothing. */
    fun timedOut(key: String, token: Int): List<Effect> {
        val op = ops[key] ?: return emptyList()
        if (op.token != token) return emptyList()
        // Never sent and still connecting: the connect failed or hangs (a fast failure can go unseen, Tron #1743).
        // Drop it, so the next request dials again instead of waiting on this socket until the idle close.
        if (!op.sent && link == Link.CONNECTING) {
            link = Link.DOWN
            auth = Auth.None
            return listOf(Effect.Disconnect) + failAll()
        }
        // Nothing heard on the socket since this was sent: the socket is dead, not the vault slow.
        if (op.sent && link == Link.UP && op.sentAt == heard) {
            link = Link.DOWN
            auth = Auth.None
            return listOf(Effect.Disconnect) + failAll()
        }
        val out = mutableListOf<Effect>()
        if (op.kind == Kind.REQ && op.sent && link == Link.UP) out += Effect.Send(closeFrame(key))
        out += finish(key, Outcome.Failed)
        return out
    }

    /** One message from the vault: [type] is the array's first element. */
    fun received(type: String, arr: JsonArray): List<Effect> {
        heard += 1
        fun str(i: Int) = (arr.getOrNull(i) as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
        return when (type) {
            "AUTH" -> {
                // One login per connection: a later challenge on a logged-in socket is not answered.
                val challenge = str(1)
                if (auth != Auth.None || challenge == null) emptyList()
                else {
                    auth = Auth.Signing
                    listOf(Effect.SignAuth(challenge))
                }
            }
            "OK" -> {
                val id = str(1) ?: return emptyList()
                val ok = (arr.getOrNull(2) as? JsonPrimitive)?.booleanOrNull
                val a = auth
                if (a is Auth.Sent && a.id == id) {
                    if (ok != true) {
                        // The vault refused our login: close; the next request starts over.
                        link = Link.DOWN
                        auth = Auth.None
                        return listOf(Effect.Disconnect) + failAll()
                    }
                    auth = Auth.Authed
                    return sendReady()
                }
                if (ops[id]?.kind != Kind.EVENT) return emptyList()
                val reason = str(3).orEmpty()
                if (ok != true && reason.startsWith("auth-required")) return authRequired(id)
                listOf(finish(id, Outcome.Accepted(ok == true || reason.startsWith("duplicate"))))
            }
            "EVENT" -> {
                val sub = str(1) ?: return emptyList()
                val op = ops[sub]?.takeIf { it.kind == Kind.REQ } ?: return emptyList()
                (arr.getOrNull(2) as? JsonObject)?.let { op.events += it }
                emptyList()
            }
            "EOSE" -> {
                val sub = str(1) ?: return emptyList()
                val op = ops[sub]?.takeIf { it.kind == Kind.REQ } ?: return emptyList()
                // The socket stays open: end the subscription on the vault too.
                listOf(Effect.Send(closeFrame(sub)), finish(sub, Outcome.Events(op.events.toList())))
            }
            "CLOSED" -> {
                val sub = str(1) ?: return emptyList()
                if (ops[sub]?.kind != Kind.REQ) return emptyList()
                if (str(2).orEmpty().startsWith("auth-required")) authRequired(sub)
                else listOf(finish(sub, Outcome.Failed))
            }
            else -> emptyList()
        }
    }

    /** Refused for want of a login: before the AUTH's OK it goes again on that OK; after it, one retry. */
    private fun authRequired(key: String): List<Effect> {
        val op = ops[key] ?: return emptyList()
        if (auth != Auth.Authed) {
            op.sent = false
            return emptyList()
        }
        if (op.retried) {
            // Logged in, and still refused after its retry: this socket's login is no good. Close it.
            link = Link.DOWN
            auth = Auth.None
            return listOf(Effect.Disconnect) + failAll()
        }
        op.retried = true
        op.sent = true
        op.sentAt = heard
        return listOf(Effect.Send(op.frame))
    }

    /** Sends every request not yet sent, unless a login is under way (they go on its OK). */
    private fun sendReady(): List<Effect> {
        if (link != Link.UP) return emptyList()
        if (auth == Auth.Signing || auth is Auth.Sent) return emptyList()
        val out = mutableListOf<Effect>()
        for ((_, op) in ops) {
            if (op.sent) continue
            op.sent = true
            op.sentAt = heard
            out += Effect.Send(op.frame)
        }
        return out
    }

    private fun finish(key: String, outcome: Outcome): Effect {
        ops.remove(key)
        return Effect.Finish(key, outcome)
    }

    private fun failAll(): List<Effect> = ops.keys.toList().map { finish(it, Outcome.Failed) }

    companion object {
        fun closeFrame(sub: String): String = "[\"CLOSE\",${JsonPrimitive(sub)}]"
    }
}

/**
 * Reading more than one answer's worth (a vault caps a REQ at [LIMIT]): newest first, each page asking `until` the
 * oldest of the last. Every version comes, whatever the kinds, in as few asks as it takes; it replaces a re-ask per
 * kind whenever the first answer hit the cap. Twin of iOS `VaultPaging`.
 */
internal object VaultPaging {
    const val LIMIT = 1000
    /** A backstop: 50,000 versions. */
    const val MAX_PAGES = 50

    /**
     * The next page's `until`, or null when [page] was the last: it came back under the limit ([known] holds every
     * id read before it). A full page that brought nothing new is one second holding a page or more of versions: the
     * next page asks from the second before it.
     */
    fun nextUntil(page: List<Pair<String, Long>>, known: Set<String>, limit: Int = LIMIT): Long? {
        if (page.size < limit) return null
        val oldest = page.minOf { it.second }
        return if (page.any { it.first !in known }) oldest else oldest - 1
    }
}
