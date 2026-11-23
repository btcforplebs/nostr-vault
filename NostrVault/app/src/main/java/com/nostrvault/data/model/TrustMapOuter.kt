package com.nostrvault.data.model

import com.nostrvault.fips.DeviceRole
import java.text.NumberFormat

/**
 * The globe's outer rings: people three or more hops out, as your desktop
 * Vault ranked them ([TrustRankCopy]), one ring per hop. Only your own globe
 * on the WOT tab draws them (plan phase 4, Logen 2026-11-22).
 *
 * - [Source.RANKED]: a rank copy is here. Rings with someone over the
 *   Discovery reach bar, labelled "found by your desktop Vault".
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
    /** The bar the counts are at, null unless ranked. */
    val bar: Double?,
) {
    enum class Source { RANKED, WAITING, INVITE }

    data class Ring(
        val hop: Int,
        /** Everyone in this ring over the bar. */
        val count: Int,
        /** The highest-scored of them, best first, at most [SHOWN_PEOPLE]. */
        val top: List<String>,
    )

    val isFaint: Boolean get() = source != Source.RANKED

    companion object {
        val NONE = TrustMapOuter(Source.INVITE, emptyList(), null)

        /** The first outer ring: past your circle ([DiscoveryReach.CIRCLE_HOPS]). */
        val FIRST_HOP = DiscoveryReach.CIRCLE_HOPS + 1
        /** Faint rings drawn with no rank: hops 3 to 5. */
        val FAINT_HOPS = FIRST_HOP..5
        /** How many people a ring's sheet and its dots show. */
        const val SHOWN_PEOPLE = 200

        /** Settings key: the invite card was put away with "Not now". Only Settings › Feed › Discovery Reach brings it back. */
        const val INVITE_HIDDEN_KEY = "globeDesktopVaultInviteHidden"

        const val FOUND_LABEL = "Found by your desktop Vault"
        const val WAITING_LABEL = "Your desktop Vault hasn't sent its ranking yet"
        const val PAIR_LINE = "Pair a desktop Vault to see distant connections"

        fun make(copy: TrustRankCopy?, bar: Double?, desktopPaired: Boolean, hidden: Set<String> = emptySet()): TrustMapOuter {
            if (copy == null || bar == null) {
                val faint = FAINT_HOPS.map { Ring(it, 0, emptyList()) }
                return TrustMapOuter(if (desktopPaired) Source.WAITING else Source.INVITE, faint, null)
            }
            val byHop = HashMap<Int, MutableList<Pair<String, Double>>>()
            for ((pubkey, person) in copy.people) {
                if (person.hop < FIRST_HOP || person.score < bar || pubkey in hidden) continue
                byHop.getOrPut(person.hop) { mutableListOf() }.add(pubkey to person.score)
            }
            val rings = byHop.keys.sorted().map { hop ->
                val people = byHop.getValue(hop)
                // Best first; equal scores by key so the order never shuffles.
                val top = people.sortedWith(compareByDescending<Pair<String, Double>> { it.second }.thenBy { it.first })
                    .take(SHOWN_PEOPLE).map { it.first }
                Ring(hop, people.size, top)
            }
            return TrustMapOuter(Source.RANKED, rings, bar)
        }

        /** A Mac (or a Linux box, which pairs as one) is among your devices. A phone is never a desktop Vault. */
        fun desktopPaired(roles: List<DeviceRole>): Boolean = roles.any { it == DeviceRole.MAC }

        /** "3 hops · 2,015". */
        fun chipText(ring: Ring): String = "${ring.hop} hops · ${NumberFormat.getIntegerInstance().format(ring.count)}"

        /** The sheet's line: "2,015 people at score 55 and up." */
        fun countText(ring: Ring, bar: Double?): String {
            val people = if (ring.count == 1) "person" else "people"
            val n = NumberFormat.getIntegerInstance().format(ring.count)
            return if (bar == null) "$n $people." else "$n $people at score ${bar.toInt()} and up."
        }
    }
}
