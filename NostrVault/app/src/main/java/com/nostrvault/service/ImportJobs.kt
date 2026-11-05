package com.nostrvault.service

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * The import jobs the relay runs inside itself (haven-go import_jobs.go, Ted #1763): `setup` is the way in, the rest
 * are the Vault's "Still to bring in" card, each run only when tapped (Logen 2026-11-05). Contract:
 * PLANS/NV_FIRST_RUN_ENTRY_PLAN_2026_11_05.md "Engine API". Pure for the tests.
 */
@Serializable
data class ImportJobs(
    val account: String = "",
    @SerialName("start_date") val startDate: String = "",
    val jobs: List<Job> = emptyList(),
) {
    @Serializable
    data class Job(
        val name: String = "",
        val status: String = NEVER,
        @SerialName("started_at") val startedAt: Long = 0,
        @SerialName("ended_at") val endedAt: Long = 0,
        val reason: String = "",
        val stored: Int = 0,
        val unread: List<Unread> = emptyList(),
        @SerialName("est_seconds") val estSeconds: Int = 0,
    ) {
        val isRunning: Boolean get() = status == RUNNING
        /** `setup` lets the person in on either: partial means a slow or silent relay, read later by older_relays. */
        val letsIn: Boolean get() = status == DONE || status == PARTIAL
    }

    @Serializable
    data class Unread(
        val relay: String = "",
        val from: String = "",
        val to: String = "",
        val why: String = "",
    )

    fun job(name: String): Job? = jobs.firstOrNull { it.name == name }

    /** The card's rows: every job but `setup`, in the engine's order. */
    val stillToBringIn: List<Job> get() = jobs.filter { it.name != SETUP }

    companion object {
        const val SETUP = "setup"
        const val NEVER = "never"
        const val RUNNING = "running"
        const val DONE = "done"
        const val PARTIAL = "partial"
        const val FAILED = "failed"
        const val CANCELLED = "cancelled"

        // RunImportJobC answers.
        const val RUN_STARTED = 0
        const val RUN_UNKNOWN = 1
        const val RUN_BUSY = 2
        const val RUN_RELAY_NOT_RUNNING = 3

        const val LOG_MARKER = "IMPORT_JOB "

        private val json = Json { ignoreUnknownKeys = true }

        fun parse(text: String?): ImportJobs? =
            text?.takeIf { it.isNotBlank() }?.let { runCatching { json.decodeFromString<ImportJobs>(it) }.getOrNull() }

        /** `IMPORT_JOB name=<job> status=<status> …` anywhere in a log line → (name, status); unknown keys ignored. */
        fun logLine(raw: String): Pair<String, String>? {
            val at = raw.indexOf(LOG_MARKER)
            if (at < 0) return null
            val fields = raw.substring(at + LOG_MARKER.length).trim().split(' ')
                .mapNotNull { p -> p.split('=', limit = 2).takeIf { it.size == 2 }?.let { it[0] to it[1] } }
                .toMap()
            val name = fields["name"] ?: return null
            val status = fields["status"] ?: return null
            return name to status
        }

        /** What a Run tap says when the engine didn't start it; null when it started. */
        fun runRefusal(code: Int): String? = when (code) {
            RUN_STARTED -> null
            RUN_BUSY -> "Another one is running. One at a time."
            RUN_RELAY_NOT_RUNNING -> "Your vault isn't running. Start it, then try again."
            else -> "That can't run on this version."
        }

        /** What each job is, in the card's words. */
        fun title(name: String): String = when (name) {
            "replies" -> "Replies and mentions"
            "older_relays" -> "Older and slower relays"
            "wider_network" -> "Your wider network"
            "list_history" -> "Old versions of your lists"
            SETUP -> "Your notes and lists"
            else -> name.replace('_', ' ').replaceFirstChar { it.uppercase() }
        }

        fun blurb(name: String): String = when (name) {
            "replies" -> "Replies, mentions and zaps to you."
            "older_relays" -> "The relays setup couldn't finish, read back from where they stopped."
            "wider_network" -> "Follows of your follows, for the globe and Global."
            "list_history" -> "Earlier copies of your lists, for Recover a List."
            else -> ""
        }

        /** "about 3 min", "about 45 s". */
        fun estimate(seconds: Int): String = when {
            seconds <= 0 -> ""
            seconds < 90 -> "about $seconds s"
            else -> "about ${(seconds + 30) / 60} min"
        }

        /** The row's state line. Partial says it is not all there; nothing says done when a relay didn't answer. */
        fun statusLine(job: Job, nowS: Long): String = when (job.status) {
            NEVER -> "Not run yet" + estimate(job.estSeconds).let { if (it.isEmpty()) "" else " · $it" }
            RUNNING -> if (job.reason == "will_resume") "Picks up where it stopped" else "Running…" +
                (if (job.stored > 0) " ${"%,d".format(job.stored)} so far" else "")
            DONE -> "Done ${ago(job.endedAt, nowS)} · ${"%,d".format(job.stored)} brought in"
            PARTIAL -> "Not all read ${ago(job.endedAt, nowS)} · ${"%,d".format(job.stored)} brought in"
            FAILED -> "Couldn't run ${ago(job.endedAt, nowS)}"
            CANCELLED -> "Cancelled ${ago(job.endedAt, nowS)}"
            else -> job.status
        }

        /** One line per range not read: "nostr.wine: 2023-01-01 to 2026-11-05 (silent)". */
        fun unreadLines(job: Job): List<String> = job.unread.map { u ->
            val host = u.relay.removePrefix("wss://").removePrefix("ws://").trimEnd('/')
            val why = when (u.why) {
                "silent" -> "didn't answer"
                "not_read_yet" -> "not read yet"
                "stopped_partway" -> "stopped partway"
                "unreachable" -> "couldn't connect"
                "" -> ""
                else -> u.why.replace('_', ' ')
            }
            "$host: ${u.from} to ${u.to}" + if (why.isEmpty()) "" else " ($why)"
        }

        private fun ago(endedAt: Long, nowS: Long): String {
            if (endedAt <= 0) return ""
            val s = (nowS - endedAt).coerceAtLeast(0)
            return when {
                s < 60 -> "just now"
                s < 3600 -> "${s / 60} min ago"
                s < 86_400 -> "${s / 3600} h ago"
                else -> "${s / 86_400} d ago"
            }
        }
    }
}
