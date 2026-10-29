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

    fun record(sha256: String, server: String, status: Int) {
        bySha.getOrPut(sha256) { ConcurrentHashMap() }[server] = status
    }

    fun clear(sha256: String) {
        bySha.remove(sha256)
    }

    /** What was recorded for [sha256] since the last [clear], and forget it. */
    fun take(sha256: String): Map<String, Int> = bySha.remove(sha256)?.toMap().orEmpty()
}
