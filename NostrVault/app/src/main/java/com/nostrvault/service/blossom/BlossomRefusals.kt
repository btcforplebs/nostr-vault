package com.nostrvault.service

import java.util.concurrent.ConcurrentHashMap

/**
 * The HTTP code each server last answered an upload of a blob with, so the
 * waiting-post queue can tell "every server said no to this file" (stop
 * trying) from "a server didn't answer" (try later). Keyed by sha256, then by
 * the server address as the mirror list spells it. iOS `BlossomRefusals`.
 */
object BlossomRefusals {
    private val bySha = ConcurrentHashMap<String, ConcurrentHashMap<String, Int>>()
    /** The words a server gave with its no (BUD-01 `X-Reason`), by blob and server. */
    private val reasonsBySha = ConcurrentHashMap<String, ConcurrentHashMap<String, String>>()

    fun record(sha256: String, server: String, status: Int, reason: String? = null) {
        bySha.getOrPut(sha256) { ConcurrentHashMap() }[server] = status
        reason?.trim()?.takeIf { it.isNotEmpty() }?.let { reasonsBySha.getOrPut(sha256) { ConcurrentHashMap() }[server] = it }
    }

    fun clear(sha256: String) {
        bySha.remove(sha256)
        reasonsBySha.remove(sha256)
    }

    /** The reasons recorded for [sha256] since the last [clear], and forget them. Read before [take]. */
    fun takeReasons(sha256: String): Map<String, String> = reasonsBySha.remove(sha256)?.toMap().orEmpty()

    /** What was recorded for [sha256] since the last [clear], and forget it. */
    fun take(sha256: String): Map<String, Int> = bySha.remove(sha256)?.toMap().orEmpty()
}
