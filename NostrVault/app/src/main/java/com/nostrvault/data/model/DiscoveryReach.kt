package com.nostrvault.data.model

import java.text.NumberFormat
import kotlin.math.ceil
import kotlin.math.roundToInt

/**
 * Settings › Feed › Discovery Reach: the slider over the desktop Vault's
 * trust rank ([TrustRankCopy]). People ranked at or over the bar are let into
 * Underrated and Discover even when they are past your web; notifications,
 * replies and every other feed keep to your web (plan phase 4, Logen
 * 2026-11-22). iOS `DiscoveryReach.swift`.
 *
 * With no rank file there is no slider and nothing changes: a phone gets
 * scores only from a desktop Vault.
 */
object DiscoveryReach {
    /** The feeds the slider widens. */
    val modes: Set<FeedMode> = setOf(FeedMode.UNDERRATED, FeedMode.DISCOVERY)

    /** Rings 1-2 are your circle; 3 and out are distant connections. */
    const val CIRCLE_HOPS = 2

    /**
     * The bar in use: the saved one, else the file's starting bar, kept
     * between the file's floor (people under it never reached the phone) and
     * 100, in whole steps. A saved bar outside 0-100 reads as unset.
     */
    fun bar(saved: Double?, copy: TrustRankCopy): Double {
        val low = ceil(copy.floor)
        val wanted = saved?.takeIf { it in 0.0..100.0 } ?: copy.viewBar
        return minOf(100.0, maxOf(low, wanted.roundToInt().toDouble()))
    }

    /** The slider's range for [copy]. */
    fun range(copy: TrustRankCopy): ClosedFloatingPointRange<Double> = minOf(ceil(copy.floor), 100.0)..100.0

    /** Who [bar] lets in past your follows, split by ring. Keys are lowercase hex (the file's own). */
    data class Admitted(val circle: Set<String>, val distant: Set<String>) {
        val isEmpty: Boolean get() = circle.isEmpty() && distant.isEmpty()

        companion object {
            val NONE = Admitted(emptySet(), emptySet())
        }
    }

    /** Everyone two or more hops out scored at or over [bar]. */
    fun admitted(copy: TrustRankCopy, bar: Double): Admitted {
        val circle = HashSet<String>()
        val distant = HashSet<String>()
        for ((pubkey, person) in copy.people) {
            if (person.hop < 2 || person.score < bar) continue
            if (person.hop <= CIRCLE_HOPS) circle += pubkey else distant += pubkey
        }
        return Admitted(circle, distant)
    }

    /** How many people [bar] lets in, for the live line under the slider. */
    data class Count(val circle: Int, val distant: Int)

    fun count(copy: TrustRankCopy, bar: Double): Count {
        var circle = 0
        var distant = 0
        for (person in copy.people.values) {
            if (person.hop < 2 || person.score < bar) continue
            if (person.hop <= CIRCLE_HOPS) circle++ else distant++
        }
        return Count(circle, distant)
    }

    /** "1,204 people in your circle and 87 distant connections". */
    fun countText(count: Count): String {
        val format = NumberFormat.getIntegerInstance()
        val people = if (count.circle == 1) "person" else "people"
        val connections = if (count.distant == 1) "distant connection" else "distant connections"
        return "${format.format(count.circle)} $people in your circle and ${format.format(count.distant)} $connections"
    }

    /** The saved value for [bar]: null when it is the file's starting bar, so a later file still moves it. */
    fun saved(bar: Double, copy: TrustRankCopy): Double? = if (bar == bar(null, copy)) null else bar

    /**
     * The gate's ranked sets: your circle (ring 2) inside, distant
     * connections (rings 3+) always rationed as loose: at most one post each
     * and a fifth of the list ([WebGate.capLoose], Logen 2026-11-22).
     */
    fun gateSets(admitted: Admitted): Pair<Set<String>, Set<String>> = admitted.circle to admitted.distant
}
