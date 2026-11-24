package com.nostrvault.data.model

import kotlin.math.roundToInt

/**
 * What the "why?" sheet says about one person (discovery phase 4): their
 * score from your Haven, their ring, and the people you follow who follow
 * them, highest score first. No mute rows and no mute weighting: whether
 * trusted people's mutes count is still Logen's open question 3.
 *
 * Only offered when your Haven's copy has a score for them, in its feed rows
 * or its globe list ([of] is null otherwise): a phone with no Haven has no
 * scores (Logen 2026-11-22).
 */
data class TrustWhy(
    /** 0-100, shown scale, whole points. */
    val score: Int,
    val hop: Int,
    /** Where the slider starts. */
    val bar: Int,
    /** Unix seconds: when your Haven ranked. */
    val rankedAt: Long,
    val followers: List<Follower>,
    /** [followers] is everyone you follow who follows them (the links file). */
    val exact: Boolean,
    /** What the live path found; null while it is still tracing. */
    val reach: TrustPath.Reach?,
    /** Hop 3 and out: your follow first, them last ([TrustChain]); null when the globe list can't say. */
    val chain: List<String>? = null,
) {
    /** One of your follows who follows them; [score] null when your Haven's copy doesn't have them. */
    data class Follower(val pubkey: String, val score: Int?)

    val overBar: Boolean get() = score >= bar

    companion object {
        /** Rows the sheet lists; the rest are counted. */
        const val SHOWN = 12

        fun of(pubkey: String, me: String, copy: TrustRankCopy?, path: TrustPath?): TrustWhy? {
            if (copy == null || pubkey.equals(me, ignoreCase = true)) return null
            val person = copy[pubkey] ?: copy.globeRow(pubkey)?.let { TrustRankCopy.Person(it.score, it.hop) } ?: return null
            // The web outranks the copy for the near rings (ProfileHopText).
            val hop = ProfileHopText.hop(pubkey, me, path, person) ?: return null
            val bridges = path?.takeIf { it.reach == TrustPath.Reach.FOLLOW || it.reach == TrustPath.Reach.BRIDGED }
                ?.let { it.all.ifEmpty { it.bridges } }.orEmpty()
            val followers = bridges
                .map { Follower(it, copy[it]?.score?.roundToInt()) }
                .sortedWith(compareByDescending<Follower> { it.score ?: -1 }.thenBy { it.pubkey })
            return TrustWhy(
                score = person.score.roundToInt(),
                hop = hop,
                bar = copy.viewBar.roundToInt(),
                rankedAt = copy.builtAt,
                followers = followers,
                exact = path?.exact == true,
                reach = path?.reach,
                chain = if (hop >= 3) TrustChain.of(pubkey, copy) else null,
            )
        }
    }
}

/** The sheet's words, kept apart so they can be tested. */
object TrustWhyText {
    fun headline(why: TrustWhy): String = "Score ${why.score} of 100"

    fun place(why: TrustWhy): String {
        val hops = if (why.hop == 1) "1 hop" else "${why.hop} hops"
        val bar = if (why.overBar) "at or over the ${why.bar} discovery starts at" else "under the ${why.bar} discovery starts at"
        return "$hops from you · $bar"
    }

    /**
     * Null when the sheet can't say: in the graph with no bridge seen (WEB/UNKNOWN),
     * or a follow whose own follows aren't known. "No one" only when the path says OUTSIDE.
     */
    fun followersTitle(why: TrustWhy): String? {
        val n = why.followers.size
        if (n == 0) return when (why.reach) {
            null -> "Checking…"
            TrustPath.Reach.OUTSIDE -> "No one you follow follows them"
            else -> null
        }
        val who = if (n == 1) "person you follow follows" else "people you follow follow"
        return if (why.exact) "$n $who them" else "At least $n $who them"
    }

    /** "How they connect" for hop 3 and out: "You > A > B > them". */
    fun chain(why: TrustWhy, name: (String) -> String): String? = why.chain?.let { TrustChain.text(it, name) }

    /** What the score is made of, in a sentence. */
    const val HOW =
        "Your desktop Vault scores people from the follows of people you trust: a follow from someone with a high score " +
            "counts for more, and trust fades with each hop. The score is yours alone and never published."

    fun more(why: TrustWhy): String? {
        val rest = why.followers.size - TrustWhy.SHOWN
        return if (rest > 0) "and $rest more" else null
    }
}
