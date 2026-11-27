package com.nostrvault.service

import java.net.URI

/**
 * The last-copy check behind "Delete from this device" (D3; iOS twin `DeleteHereGate`). The local file may go only
 * when, asked just now, at least one OTHER place proves it holds the same bytes. Logen (2026-11-27): the owner's Mac
 * or home box counts as a safe copy, like any media server; this device's own relay never does.
 *
 * Fail closed: a server that did not answer, answered oddly, or whose length does not match this file counts as not
 * holding it. Nothing cached: the caller asks every server again for this one decision.
 */
object DeleteHereGate {
    /** One server's answer to `GET <server>/<sha256>` with `Range: bytes=0-0`. */
    data class Answer(
        val status: Int,
        val contentType: String? = null,
        val contentLength: String? = null,
        val contentRange: String? = null,
        /** Where redirects ended. */
        val finalUrl: String? = null,
    )

    sealed interface Decision {
        data class Allowed(val holders: List<String>) : Decision
        data class Refused(val why: String) : Decision
    }

    /** Whether [a] proves the server holds this file, byte length and all (200 with the whole length, or 206 with `bytes 0-0/<total>`). */
    fun proves(a: Answer, sha256: String, localSize: Long): Boolean {
        if (localSize <= 0) return false
        if (a.contentType?.lowercase()?.startsWith("text/html") == true) return false
        if (a.finalUrl != null && !a.finalUrl.lowercase().contains(sha256.lowercase())) return false
        return when (a.status) {
            200 -> a.contentLength?.trim()?.toLongOrNull() == localSize
            206 -> a.contentRange?.trim()?.substringAfterLast('/', "")?.toLongOrNull() == localSize
            else -> false
        }
    }

    /** [servers] minus this device's own relay (loopback, or [ownHosts]), each once. */
    fun candidates(servers: List<String>, ownHosts: Set<String>): List<String> {
        val seen = HashSet<String>()
        return servers.filter { s ->
            val host = runCatching { URI(s).host?.lowercase() }.getOrNull()
            !host.isNullOrEmpty() && host !in setOf("127.0.0.1", "localhost", "0.0.0.0", "::1", "[::1]") &&
                host !in ownHosts && seen.add(s)
        }
    }

    /** The decision from each candidate's fresh answer (null = could not ask). */
    fun decide(answers: Map<String, Answer?>, sha256: String, localSize: Long): Decision {
        if (localSize <= 0) return Decision.Refused("This file isn't on this device.")
        if (answers.isEmpty()) return Decision.Refused("No media server or other device to keep it. Copy it to a server first.")
        val holders = answers.filter { (_, a) -> a != null && proves(a, sha256, localSize) }.keys.sorted()
        if (holders.isNotEmpty()) return Decision.Allowed(holders)
        if (answers.values.all { it == null }) {
            return Decision.Refused("None of your servers answered just now, so this may be the only copy. Try again later.")
        }
        return Decision.Refused("No server has a full copy of this file, so it would be lost. Copy it to a server first.")
    }
}
