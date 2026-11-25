package com.nostrvault.fips

/**
 * Rank only (haven-go copyv2_rank_only.go, Logen 2026-11-25): a phone paired with a Mac or a box pulls its trust rank
 * right away, with no first copy. A device this one copied from keeps its catch-up, which brings the rank as before;
 * every other paired desktop gets a rank pull (RankPullC), signed by this device's mesh key, never the account key.
 * Twin of Apple's `MeshRankPull.swift`.
 */
object MeshRankPull {
    const val START_PATH = "/copy/v2/rank-start"
    const val PULLED_MARKER = "RANK_PULLED peer="

    /** A pull's end line: `RANK_PULLED peer=<npub> got=<n>[ error=<code>]`. */
    data class Pulled(val peer: String, val got: Int, val error: String)

    /** The kind 27235 tags for POST <base>/copy/v2/rank-start, `p` = A's mesh npub ([MeshKeyAuth.copyStartTags]). */
    fun startTags(httpBase: String, receiver: String): List<List<String>>? {
        val p = receiver.trim()
        if (p.isEmpty() || httpBase.isBlank()) return null
        return listOf(listOf("u", httpBase.trimEnd('/') + START_PATH), listOf("method", "POST"), listOf("p", p))
    }

    /** The end line, or null for any other line (a timestamp may lead it). */
    fun parse(line: String): Pulled? {
        val i = line.indexOf(PULLED_MARKER)
        if (i < 0 || (i > 0 && !line[i - 1].isWhitespace())) return null
        val fields = line.substring(i).split(' ').mapNotNull { part ->
            part.split('=', limit = 2).takeIf { it.size == 2 }?.let { it[0] to it[1] }
        }.toMap()
        val peer = fields["peer"]?.takeIf { it.startsWith("npub1") && it.length == 63 } ?: return null
        val got = fields["got"]?.toIntOrNull() ?: return null
        return Pulled(peer, got, fields["error"].orEmpty())
    }

    /**
     * The paired desktops (a Mac or a box, [desktops]) that get a rank pull: not one this device copied from (its
     * catch-up brings the rank) and not the one a first copy is pending with.
     */
    fun peers(desktops: List<String>, copied: Map<String, Long>, pending: String?): List<String> =
        desktops.filter { it !in copied && it != pending }.distinct()

    /** Of those, the ones due now: never pulled since the app started, or last pulled an hour ago. */
    fun due(desktops: List<String>, copied: Map<String, Long>, pending: String?, pulledAt: Map<String, Long>, nowS: Long): List<String> =
        peers(desktops, copied, pending).filter { p -> pulledAt[p]?.let { nowS - it >= MeshRankNudge.RECHECK_EVERY_S } ?: true }

    /** A pull cut short (lost link, stopped) is due again at once. */
    fun cutShort(error: String): Boolean = error == "unreachable" || error == "cancelled"
}
