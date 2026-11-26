package com.nostrvault.data.model

/**
 * The path from someone on a hop sphere back to you (Logen 2026-11-25):
 * their `via` in the rank copy's globe list, that person's `via`, and so on
 * in toward your follows, each with the ring they sit on. The globe draws a
 * line through each one's spot on its layer to you at the centre
 * ([com.nostrvault.ui.components.GlobeChainPainter]); a link that is not on
 * screen is skipped. iOS `Models/GlobeChain.swift`.
 */
object GlobeChain {
    /** [hop]: the ring they are on, 1 for your follows, null when unknown. */
    data class Link(val key: String, val hop: Int?)

    /**
     * [key] first, then each `via` in, ending at one of your follows (hop 1)
     * or wherever the copy stops knowing. Never loops, never longer than the
     * rings there are.
     */
    fun links(key: String, copy: TrustRankCopy?, follows: Set<String>): List<Link> {
        val first = copy?.globeRow(key) ?: return emptyList()
        val out = mutableListOf(Link(key, first.hop))
        val seen = hashSetOf(key)
        var via = first.via
        while (via.isNotEmpty() && seen.add(via) && out.size <= TrustRankCopy.CEILING_HOP) {
            if (via in follows) {
                out += Link(via, 1)
                break
            }
            val row = copy.globeRow(via)
            out += Link(via, row?.hop)
            via = row?.via ?: ""
        }
        return out
    }

    /**
     * The points a path is drawn through, from each link's point where it is
     * on screen (null where not), and whether the first is the tapped person:
     * when theirs is missing the line still runs from the next known point,
     * but no start ring marks someone else.
     */
    fun <P : Any> path(found: List<P?>): Pair<List<P>, Boolean> =
        Pair(found.filterNotNull(), found.firstOrNull() != null)
}
