package com.nostrvault.data.model

import com.nostrvault.fips.DeviceRole
import java.text.NumberFormat

/**
 * The globe's outer rings: people three or more hops out, as your desktop
 * Vault ranked them ([TrustRankCopy]), one ring per hop. Only your own globe
 * on the WOT tab draws them (plan phase 4, Logen 2026-11-22).
 *
 * - [Source.RANKED]: a rank copy is here. Each ring's top
 *   [TrustRankCopy.GLOBE_PER_RING] from the copy's globe list, whatever
 *   their score (no bar: the feed keeps its bar, the globe shows the best
 *   of each ring), fainter the further out ([fade]).
 * - [Source.WAITING]: a desktop Vault is paired but has not sent a rank yet.
 *   Faint rings, no people.
 * - [Source.INVITE]: no desktop Vault. Faint rings and the invite card.
 *
 * iOS `Models/TrustMapOuter.swift`.
 */
data class TrustMapOuter(
    val source: Source,
    /** Inner to outer. Empty when ranked with nobody out there. */
    val rings: List<Ring>,
) {
    enum class Source { RANKED, WAITING, INVITE }

    data class Ring(
        val hop: Int,
        /** The ring's best-ranked people, best first, at most [TrustRankCopy.GLOBE_PER_RING]. */
        val top: List<String>,
        /** Each of [top]'s link one ring in: the zoomed globe draws a line to them ([GlobeRingZoom]). */
        val via: Map<String, String> = emptyMap(),
        /**
         * The people ranked after [top], best first ([TrustRankCopy.haze]): the
         * zoomed-out ring's faint, untappable dots ([com.nostrvault.ui.components.GlobeHaze]).
         */
        val haze: List<String> = emptyList(),
    ) {
        val count: Int get() = top.size
    }

    val isFaint: Boolean get() = source != Source.RANKED

    /**
     * A hop layer (Hop 3, 4, 5) is picked only once a desktop Vault's
     * ranking is on this device with that ring in it; until then the picker
     * greys it out, as the reason to run one (Logen 2026-11-24).
     */
    fun unlocks(hop: Int): Boolean = source == Source.RANKED && rings.any { it.hop == hop }

    companion object {
        val NONE = TrustMapOuter(Source.INVITE, emptyList())

        /** The first outer ring: past your circle ([DiscoveryReach.CIRCLE_HOPS]). */
        val FIRST_HOP = DiscoveryReach.CIRCLE_HOPS + 1
        /** The rings drawn: hops 3 to 5 ([TrustRankCopy.GLOBE_HOP]). Faint with no rank. */
        val FAINT_HOPS = FIRST_HOP..TrustRankCopy.GLOBE_HOP

        /** Settings key: the invite card was put away with "Not now". Only Settings › Feed › Discovery Reach brings it back. */
        const val INVITE_HIDDEN_KEY = "globeDesktopVaultInviteHidden"

        const val FOUND_LABEL = "Found by your desktop Vault"
        const val WAITING_LABEL = "Your desktop Vault hasn't sent its ranking yet"
        const val PAIR_LINE = "Pair a desktop Vault to see distant connections"
        /** The line a greyed hop shows when tapped. */
        const val LOCKED_LINE = "A desktop Vault unlocks the far rings"

        fun make(copy: TrustRankCopy?, desktopPaired: Boolean, hidden: Set<String> = emptySet()): TrustMapOuter {
            if (copy == null) {
                val faint = FAINT_HOPS.map { Ring(it, emptyList()) }
                return TrustMapOuter(if (desktopPaired) Source.WAITING else Source.INVITE, faint)
            }
            // A ring's top is everyone in it who shows above 0, best first, up to
            // GLOBE_PER_RING; its chain links come after. A short ring's links follow
            // its top straight away and can only show 0, so 0 rows are never top.
            val byHop = HashMap<Int, MutableList<String>>()
            val via = HashMap<Int, MutableMap<String, String>>()
            val seen = HashMap<Int, Int>()
            for (row in copy.globe) {
                if (row.hop !in FAINT_HOPS || row.score <= 0.0) continue
                val n = seen.getOrDefault(row.hop, 0)
                if (n >= TrustRankCopy.GLOBE_PER_RING) continue
                seen[row.hop] = n + 1
                if (row.pubkey in hidden) continue
                byHop.getOrPut(row.hop) { mutableListOf() }.add(row.pubkey)
                if (row.via.isNotEmpty() && row.via !in hidden) via.getOrPut(row.hop) { mutableMapOf() }[row.pubkey] = row.via
            }
            return TrustMapOuter(Source.RANKED, byHop.keys.sorted().map { hop ->
                val top = byHop.getValue(hop)
                val inTop = top.toHashSet()
                val haze = copy.haze[hop].orEmpty().filter { it !in hidden && it !in inTop }
                Ring(hop, top, via[hop].orEmpty(), haze)
            })
        }

        /** How strongly a ring and its dots are drawn: hop 3 full, hop 4 about 60%, hop 5 about 35%. */
        fun fade(hop: Int): Float = when {
            hop <= FIRST_HOP -> 1f
            hop == FIRST_HOP + 1 -> 0.6f
            else -> 0.35f
        }

        /** A Mac (or a Linux box, which pairs as one) is among your devices. A phone is never a desktop Vault. */
        fun desktopPaired(roles: List<DeviceRole>): Boolean = roles.any { it == DeviceRole.MAC }

        /**
         * How many people a hop's sphere draws: its top and its haze. Null while
         * the copy has no haze for it: then the ring is just its top 300, a cap,
         * so the Hop chip shows no number (Logen 2026-11-25). iOS `TrustMapOuter.shownCount`.
         */
        fun shownCount(ring: Ring): Int? = if (ring.haze.isEmpty()) null else ring.top.size + ring.haze.size

        /**
         * "3 hops". The rank copy has no ring total, so no "best 300 of N"; the
         * sheet's [countText] says how many are shown. Never "people at 55 and up".
         */
        fun chipText(ring: Ring): String = "${ring.hop} hops"

        /** The sheet's line: "The 300 best-ranked people in this ring." */
        fun countText(ring: Ring): String =
            if (ring.count == 1) "The 1 best-ranked person in this ring."
            else "The ${NumberFormat.getIntegerInstance().format(ring.count)} best-ranked people in this ring."
    }
}
