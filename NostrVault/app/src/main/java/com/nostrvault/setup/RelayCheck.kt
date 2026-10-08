package com.nostrvault.setup

import java.net.URI
import java.util.Locale

/**
 * "I already use Nostr"'s relay check, before the import: which relays to
 * import from. The import reads one fixed list (`importSeedRelays`) and only
 * gives up when every relay on it fails, each after a long timeout, so one
 * dead relay can stall it and notes kept elsewhere never arrive. The check
 * puts the person's own write relays first, asks every relay for one of
 * their notes at once, and switches off the ones that don't answer.
 * Same as iOS `RelayCheck`.
 */
object RelayCheck {
    /** Past this a relay is "slow". Past [TIMEOUT_SECONDS] it's "not answering". */
    const val SLOW_AFTER_SECONDS = 2.0
    const val TIMEOUT_SECONDS = 4.0

    sealed class Result {
        data object Checking : Result()
        /** Answered in time. [hasNotes]: it sent one of their notes. */
        data class Ready(val seconds: Double, val hasNotes: Boolean) : Result()
        data class Slow(val seconds: Double, val hasNotes: Boolean) : Result()
        data object NotAnswering : Result()
        /** Answered, but refused the request (CLOSED): e.g. a chat-only relay. */
        data object Refused : Result()
        /** Wants NIP-42 sign-in before it answers ("auth-required"). */
        data object NeedsSignIn : Result()

        /** Whether the import could read from it at all. */
        val canImport: Boolean get() = this is Ready || this is Slow

        /** On by default: answered, and if slow, only when it has their notes. */
        val onByDefault: Boolean
            get() = when (this) {
                is Ready -> true
                is Slow -> hasNotes
                else -> false
            }

        val label: String
            get() = when (this) {
                Checking -> "Checking…"
                is Ready -> if (hasNotes) "Ready · ${format(seconds)}" else "Ready · none of your notes found · ${format(seconds)}"
                is Slow -> if (hasNotes) "Slow, but has your notes · ${format(seconds)}" else "Slow · none of your notes found · ${format(seconds)}"
                NotAnswering -> "Not answering · skipped"
                Refused -> "Doesn't keep notes · skipped"
                NeedsSignIn -> "Needs sign-in · skipped"
            }

        companion object {
            fun answeredAfter(seconds: Double?, hasNotes: Boolean): Result = when {
                seconds == null || seconds > TIMEOUT_SECONDS -> NotAnswering
                seconds > SLOW_AFTER_SECONDS -> Slow(seconds, hasNotes)
                else -> Ready(seconds, hasNotes)
            }

            private fun format(seconds: Double) = String.format(Locale.US, "%.1fs", seconds)
        }
    }

    data class Row(
        val url: String,
        /** From their own relay list (kind 10002). */
        val isYours: Boolean,
        val result: Result = Result.Checking,
        val isOn: Boolean = false,
    )

    /** Their write relays first (marked yours), then the defaults, without
     *  duplicates. [relayListTags] are the kind-10002 `r` tags; a relay marked
     *  "read" only is where they read, not where their notes are. */
    fun rows(relayListTags: List<List<String>>, defaults: List<String>): List<Row> {
        val seen = mutableSetOf<String>()
        val rows = mutableListOf<Row>()
        for (tag in relayListTags) {
            if (tag.firstOrNull() != "r" || tag.size < 2) continue
            if (tag.getOrNull(2) == "read") continue
            val url = normalize(tag[1]) ?: continue
            if (seen.add(url)) rows.add(Row(url, isYours = true))
        }
        for (raw in defaults) {
            val url = normalize(raw) ?: continue
            if (seen.add(url)) rows.add(Row(url, isYours = false))
        }
        return rows
    }

    /** `wss://host[:port][/path]`, lowercased host, no trailing slash. A bare
     *  host gets `wss://`. Anything that isn't a websocket address is null. */
    fun normalize(raw: String): String? {
        var text = raw.trim()
        if (text.isEmpty() || text.contains(" ")) return null
        if (!text.contains("://")) text = "wss://$text"
        val uri = runCatching { URI(text) }.getOrNull() ?: return null
        val scheme = uri.scheme?.lowercase() ?: return null
        if (scheme != "wss" && scheme != "ws") return null
        val host = uri.host?.lowercase() ?: return null
        if (!host.contains(".") || host.startsWith(".") || host.endsWith(".")) return null
        val port = if (uri.port != -1) ":${uri.port}" else ""
        val path = (uri.rawPath ?: "").removeSuffix("/")
        return "$scheme://$host$port$path"
    }

    /** "6 relays are ready to import from. 1 didn't answer, so we'll skip it." */
    fun summary(rows: List<Row>): String {
        val on = rows.count { it.isOn }
        val dead = rows.count { it.result == Result.NotAnswering }
        var text = when (on) {
            0 -> "No relays are ready to import from. Add one, or check again."
            1 -> "1 relay is ready to import from."
            else -> "$on relays are ready to import from."
        }
        if (dead == 1) text += " 1 didn't answer, so we'll skip it."
        if (dead > 1) text += " $dead didn't answer, so we'll skip them."
        val refused = rows.count { it.result == Result.Refused || it.result == Result.NeedsSignIn }
        if (refused == 1) text += " 1 won't share notes."
        if (refused > 1) text += " $refused won't share notes."
        return text
    }

    /** A CLOSED reply: NIP-01 machine-readable prefix "auth-required:" means
     *  it wants sign-in; anything else, it won't serve this request. */
    fun closedResult(reason: String?): Result =
        if ((reason ?: "").startsWith("auth-required")) Result.NeedsSignIn else Result.Refused

    /** What the import reads, in order. */
    fun importList(rows: List<Row>): List<String> = rows.filter { it.isOn }.map { it.url }
}
