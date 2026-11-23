package com.nostrvault.fips

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive

/**
 * The trust rank nudge (haven-go copyv2_nudge.go). A Mac that has just ranked tells the own devices that copy from
 * it; their engine logs `RANK_READY peer=<npub>` and [MeshCopyStarter.rankReady] catches up with that device, which
 * brings the new result down. A device that misses the nudge gets it from its hourly check. Mesh keys only, never
 * the account key. Android never ranks, so it only receives. Twin of Apple's `MeshRankNudge.swift`.
 */
object MeshRankNudge {
    const val READY_MARKER = "RANK_READY peer="
    /** While the app runs, every device it copies from is checked this often. */
    const val RECHECK_EVERY_S = 60L * 60

    /** The npub a `RANK_READY` line names, or null for any other line. */
    fun readyPeer(line: String): String? {
        val i = line.indexOf(READY_MARKER)
        if (i < 0 || (i > 0 && !line[i - 1].isWhitespace())) return null
        val peer = line.substring(i + READY_MARKER.length).takeWhile { !it.isWhitespace() }
        val ok = peer.startsWith("npub1") && peer.length == 63 && peer.all { it in 'a'..'z' || it in '0'..'9' }
        return peer.takeIf { ok }
    }

    /** CopyHeldPeersC's JSON array of npubs; empty when it isn't one. */
    fun parseHeld(json: String?): List<String> {
        if (json.isNullOrBlank()) return emptyList()
        val arr = runCatching { Json.parseToJsonElement(json) as? JsonArray }.getOrNull() ?: return emptyList()
        return arr.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content?.takeIf { s -> s.startsWith("npub1") } }
    }
}
