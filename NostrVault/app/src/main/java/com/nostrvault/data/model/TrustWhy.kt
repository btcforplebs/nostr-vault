package com.nostrvault.data.model

import kotlin.math.roundToInt

/**
 * What the "why?" sheet says about one person (discovery phase 4): their
 * score from your Haven, their ring, and the people you follow who follow
 * them, highest score first. No mute rows and no mute weighting: whether
 * trusted people's mutes count is still Logen's open question 3.
 *
 * Only offered when your Haven's copy has a score for them ([of] is null
 * otherwise): a phone with no Haven has no scores (Logen 2026-11-22).
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
) {
    /** One of your follows who follows them; [score] null when your Haven's copy doesn't have them. */
    data class Follower(val pubkey: String, val score: Int?)

    val overBar: Boolean get() = score >= bar

    companion object {
        /** Rows the sheet lists; the rest are counted. */
        const val SHOWN = 12

        fun of(pubkey: String, me: String, copy: TrustRankCopy?, path: TrustPath?): TrustWhy? {
            if (copy == null || pubkey.equals(me, ignoreCase = true)) return null
            val person = copy[pubkey] ?: return null
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

    fun followersTitle(why: TrustWhy): String = when {
        why.followers.isEmpty() -> "No one you follow follows them"
        why.followers.size == 1 -> "1 person you follow follows them"
        why.exact -> "${why.followers.size} people you follow follow them"
        else -> "At least ${why.followers.size} people you follow follow them"
    }

    /** What the score is made of, in a sentence. */
    const val HOW =
        "Your Haven scores people from the follows of people you trust: a follow from someone with a high score " +
            "counts for more, and trust fades with each hop. The score is yours alone and never published."

    fun more(why: TrustWhy): String? {
        val rest = why.followers.size - TrustWhy.SHOWN
        return if (rest > 0) "and $rest more" else null
    }
}
