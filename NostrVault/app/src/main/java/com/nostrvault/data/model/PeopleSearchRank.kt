package com.nostrvault.data.model

import java.text.Normalizer
import java.util.Locale

/**
 * The one order every box that finds a person uses (search plan §1a, Logen go
 * 5d1ce4cb): the Search tab, the WoT globe's Find someone, the Vault's People,
 * mentions and the message pickers. Pure. iOS twin:
 * `Models/PeopleSearchRank.swift` (A3); web: `net/people-rank.js`.
 *
 * Sort key, lowest first:
 * 1. **Closeness:** -1 in this thread (mentions only) · 0 you · 1 follows ·
 *    2 your web · 3 further out (3+ steps, from the Haven's rank copy) ·
 *    4 outside. 3+ steps counts as inside your web (Logen 5d1ce4cb #6).
 * 2. **Name match:** exact > starts with > a word starts with > contains >
 *    about only, on the display name, name and NIP-05, case and accents folded.
 * 3. **Trust score** from the rank copy, high first.
 * 4. Shorter name, then pubkey, so the order holds while results stream in.
 *
 * Blocked people are always dropped. No follower or engagement counts: they
 * are cheap to fake.
 */
object PeopleSearchRank {

    /** Who is how close to you. */
    class Circle(
        own: Set<String>,
        val follows: Set<String>,
        /** Your web: follows of follows and the relay's WoT graph. */
        val web: Set<String>,
        /** The Haven's rank copy: hops 2+ and trust scores. Null without a Haven. */
        val copy: TrustRankCopy? = null,
        /** The people in the thread being replied to; only mentions set it. */
        val thread: Set<String> = emptySet(),
    ) {
        val own: Set<String> = own.mapTo(HashSet()) { it.lowercase() }

        fun score(pubkey: String): Double = copy?.get(pubkey)?.score ?: 0.0
    }

    object Tier {
        const val THREAD = -1
        const val YOU = 0
        const val FOLLOW = 1
        const val WEB = 2
        const val FURTHER = 3
        const val OUTSIDE = 4
    }

    /** Someone a box found: their key and what they go by. */
    data class Person(
        val pubkey: String,
        val displayName: String? = null,
        val name: String? = null,
        val nip05: String? = null,
        val about: String? = null,
    ) {
        /**
         * The names a match is judged on; NIP-05 also by its part before the
         * `@` (none for `_@`, which stands for the domain).
         */
        val names: List<String>
            get() {
                val out = listOfNotNull(displayName, name).filter { it.isNotEmpty() }.toMutableList()
                if (!nip05.isNullOrEmpty()) {
                    out += nip05
                    val at = nip05.indexOf('@')
                    if (at >= 0) {
                        val local = nip05.substring(0, at)
                        if (local.isNotEmpty() && local != "_") out += local
                    }
                }
                return out
            }
    }

    /** A cached profile as the ranker sees it. */
    fun person(profile: FeedProfile): Person =
        Person(profile.pubkey, profile.displayName, profile.name, profile.nip05, profile.about)

    fun tier(pubkey: String, circle: Circle): Int {
        val key = pubkey.lowercase()
        return when {
            pubkey in circle.thread || key in circle.thread -> Tier.THREAD
            key in circle.own -> Tier.YOU
            pubkey in circle.follows || key in circle.follows -> Tier.FOLLOW
            pubkey in circle.web || key in circle.web -> Tier.WEB
            else -> when (val hop = circle.copy?.get(key)?.hop) {
                null -> Tier.OUTSIDE
                else -> if (hop <= 2) Tier.WEB else Tier.FURTHER
            }
        }
    }

    /**
     * Inside your web: you, follows, your web and people 3+ steps away. The
     * rest folds under "N from outside your web", even an exact name (Logen
     * 5d1ce4cb #1).
     */
    fun isInside(pubkey: String, circle: Circle): Boolean = tier(pubkey, circle) < Tier.OUTSIDE

    // ── Name match ──

    object Match {
        const val EXACT = 0
        const val PREFIX = 1
        const val WORD_PREFIX = 2
        const val CONTAINS = 3
        const val ABOUT_ONLY = 4
        /** A source matched on something we cannot see (a search relay's own index): last when a box keeps it. */
        const val UNSEEN = 5
    }

    private val marks = Regex("\\p{Mn}+")

    /** Case-, accent- and width-folded, trimmed. "Zoë" and "zoe" are the same. */
    fun fold(text: String): String =
        marks.replace(Normalizer.normalize(text, Normalizer.Form.NFKD), "").lowercase(Locale.ROOT).trim()

    /** How well [person] matches the folded query; null for no match at all. */
    fun match(folded: String, person: Person): Int? {
        if (folded.isEmpty()) return null
        var best: Int? = null
        for (raw in person.names) {
            val name = fold(raw)
            val m = when {
                name == folded -> Match.EXACT
                name.startsWith(folded) -> Match.PREFIX
                words(name).any { it.startsWith(folded) } -> Match.WORD_PREFIX
                name.contains(folded) -> Match.CONTAINS
                else -> null
            }
            if (m != null && m < (best ?: Int.MAX_VALUE)) best = m
            if (best == Match.EXACT) break
        }
        if (best == null && person.about?.let { fold(it).contains(folded) } == true) best = Match.ABOUT_ONLY
        return best
    }

    private fun words(name: String): List<String> =
        name.splitWhere { !Character.isLetter(it.code) && !Character.isDigit(it.code) }

    private inline fun String.splitWhere(isSeparator: (Char) -> Boolean): List<String> {
        val out = ArrayList<String>()
        val word = StringBuilder()
        for (c in this) {
            if (isSeparator(c)) {
                if (word.isNotEmpty()) out += word.toString()
                word.setLength(0)
            } else {
                word.append(c)
            }
        }
        if (word.isNotEmpty()) out += word.toString()
        return out
    }

    /** The shortest name, for the tie-break; people with no name sort after. */
    private fun length(person: Person): Int =
        person.names.minOfOrNull { it.codePointCount(0, it.length) } ?: Int.MAX_VALUE

    // ── Ranking ──

    private class Keyed<T>(val item: T, val tier: Int, val match: Int, val score: Double, val length: Int, val key: String)

    private val order = compareBy<Keyed<*>>({ it.tier }, { it.match })
        .thenByDescending { it.score }
        .thenBy { it.length }
        .thenBy { it.key }

    /**
     * [items] in rank order, blocked people dropped, each pubkey once.
     * [keepUnmatched]: keep people the query does not match in any field we
     * hold (a search relay matched them on its own index), last in their
     * tier. Boxes that match locally leave it off and drop them.
     */
    fun <T> rank(
        items: Iterable<T>,
        query: String,
        circle: Circle,
        blocked: Set<String> = emptySet(),
        keepUnmatched: Boolean = false,
        limit: Int? = null,
        person: (T) -> Person,
    ): List<T> {
        val folded = fold(query)
        val seen = HashSet<String>()
        val keyed = ArrayList<Keyed<T>>()
        for (item in items) {
            val p = person(item)
            val key = p.pubkey.lowercase()
            if (p.pubkey in blocked || key in blocked || !seen.add(key)) continue
            val found = match(folded, p)
            if (found == null && !keepUnmatched) continue
            keyed += Keyed(item, tier(p.pubkey, circle), found ?: Match.UNSEEN, circle.score(key), length(p), key)
        }
        keyed.sortWith(order)
        val ranked = keyed.map { it.item }
        return if (limit != null) ranked.take(limit) else ranked
    }

    /** Ranked, then split by your web: inside first, the rest for the fold. Order holds on both sides. */
    fun <T> split(
        items: Iterable<T>,
        query: String,
        circle: Circle,
        blocked: Set<String> = emptySet(),
        keepUnmatched: Boolean = false,
        person: (T) -> Person,
    ): Pair<List<T>, List<T>> =
        rank(items, query, circle, blocked, keepUnmatched, person = person)
            .partition { isInside(person(it).pubkey, circle) }

    /**
     * The fold may open by itself when the only exact name match is in it
     * (Logen 5d1ce4cb #1): it is who you were looking for.
     */
    fun <T> outsideHoldsTheOnlyExactMatch(inside: List<T>, outside: List<T>, query: String, person: (T) -> Person): Boolean {
        val folded = fold(query)
        return inside.none { match(folded, person(it)) == Match.EXACT } &&
            outside.any { match(folded, person(it)) == Match.EXACT }
    }
}
