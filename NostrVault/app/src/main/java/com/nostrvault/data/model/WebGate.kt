package com.nostrvault.data.model

import com.nostrvault.util.PublicKeyRegistry

/**
 * Who a feed lets in from past your follows, and how far it reaches: the
 * Android twin of iOS `WebGate.swift` (Logen 2026-11-18), ported for the
 * discovery engine (phase 1.5), names as on iOS since 0B.
 *
 * What is ported: the web question. A signer is
 * 1. [Verdict.INSIDE] when it is one of your accounts or a key the surface
 *    always shows;
 * 2. [Verdict.OUTSIDE] (or inside on reach [Reach.EVERYONE]) when its secret
 *    key is public ([PublicKeyRegistry]);
 * 3. [Verdict.INSIDE] in your web, or (Underrated and Discover only) ranked
 *    over the Discovery reach bar ([Web.ranked]);
 * 4. [Verdict.INSIDE] anywhere when the reach is [Reach.EVERYONE];
 * 5. [Verdict.LOOSE] when the reach is [Reach.WEB_AND_LOOSE] and it is one
 *    hop past your web, or always for a ranked distant connection
 *    ([Web.rankedLoose], always rationed);
 * 6. [Verdict.OUTSIDE] otherwise.
 *
 * What is not: iOS judges blocks and the mute list inside the gate too
 * ("blocked", first). Android still drops those before the gate
 * ([com.nostrvault.service.FeedFilterEngine.involvesBlocked], the mute list),
 * so there is no BLOCKED verdict here yet.
 *
 * It fails closed: with no graph, or the follow list not yet known, nothing
 * is one hop out ([loose]).
 */
object WebGate {

    enum class Verdict { INSIDE, LOOSE, OUTSIDE }

    /**
     * How far a surface reaches. Only a feed has a setting ([FeedReach]);
     * every other surface is [WEB]. [stored] is the word saved in
     * `HavenConfig.feedReach`, the same as on iOS: [WEB_AND_LOOSE] keeps
     * "webAndHop3" whatever it is called.
     */
    enum class Reach(val stored: String) {
        WEB("web"),

        /** Your web plus a few one hop past it, rationed by [capLoose]. */
        WEB_AND_LOOSE("webAndHop3"),

        /** A Global-style feed with the shield on Everyone. */
        EVERYONE("everyone");

        companion object {
            fun fromStored(word: String?): Reach? = entries.firstOrNull { it.stored == word }
        }
    }

    /** One account's web, built once and read for every note. Keys are lowercase hex. */
    class Web(
        own: Set<String>,
        web: Set<String>,
        loose: Set<String> = emptySet(),
        /** Ranked over the Discovery reach bar, judged as the web is ([DiscoveryReach]). Lowercase hex. */
        val ranked: Set<String> = emptySet(),
        /** Ranked over the bar but rationed as [Verdict.LOOSE] whatever the reach ([WebGate.capLoose]). */
        val rankedLoose: Set<String> = emptySet(),
    ) {
        /** Every account on this device, the one being judged for included. */
        val own: Set<String> = lowered(own)
        val web: Set<String> = lowered(web)

        /** One hop past [web], never in it. A set already [cleanLoose]d is used as it is. */
        val loose: Set<String> = lowered(loose).let { l -> if (l.none { it in this.web }) l else l - this.web }
    }

    fun judge(
        signer: String,
        web: Web,
        reach: Reach = Reach.WEB,
        always: Set<String> = emptySet(),
        isPublic: (String) -> Boolean = PublicKeyRegistry::isPublic,
    ): Verdict {
        val key = signer.lowercase()
        if (key.isEmpty()) return Verdict.OUTSIDE
        if (key in web.own || always.any { it.equals(key, ignoreCase = true) }) return Verdict.INSIDE
        // A key anyone can post with is no longer the person you trusted.
        if (isPublic(key)) return if (reach == Reach.EVERYONE) Verdict.INSIDE else Verdict.OUTSIDE
        if (key in web.web || key in web.ranked) return Verdict.INSIDE
        return when {
            reach == Reach.EVERYONE -> Verdict.INSIDE
            reach == Reach.WEB_AND_LOOSE && key in web.loose -> Verdict.LOOSE
            key in web.rankedLoose -> Verdict.LOOSE
            else -> Verdict.OUTSIDE
        }
    }

    /**
     * Most one-hop-out rows a list shows: a fifth of its other rows, and
     * never fewer than [LOOSE_FLOOR], so a feed made mostly of them still
     * shows a few. iOS `looseFloor` / `looseShare`.
     */
    const val LOOSE_FLOOR = 10
    const val LOOSE_SHARE = 5

    /**
     * [items] with the one-hop-out rows rationed, order kept: top-level posts
     * only (a reply from there goes), one per author, and at most
     * max([LOOSE_FLOOR], other rows / [LOOSE_SHARE]). Other verdicts pass
     * through untouched. iOS `WebGate.capLoose`.
     */
    fun <T> capLoose(items: List<T>, verdict: (T) -> Verdict, author: (T) -> String, isReply: (T) -> Boolean): List<T> {
        val verdicts = items.map(verdict)
        val others = verdicts.count { it != Verdict.LOOSE }
        val cap = maxOf(LOOSE_FLOOR, others / LOOSE_SHARE)
        var shown = 0
        val authors = HashSet<String>()
        val out = ArrayList<T>(items.size)
        for ((item, v) in items.zip(verdicts)) {
            if (v != Verdict.LOOSE) { out += item; continue }
            if (shown >= cap || isReply(item) || !authors.add(author(item).lowercase())) continue
            shown++
            out += item
        }
        return out
    }

    /**
     * The hop past the account's web, by iOS `WebGate.layers` (its `loose`
     * half; Android keeps its own web, [AccountWeb.narrow]).
     *
     * @param saved the relay's saved web (`wot_cache.json`).
     * @param follows the open account's follows; empty while the list loads.
     * @param counts how many of [follows] follow each person
     *   ([AccountWeb.vouchCounts]); null when the links file is missing or
     *   unreadable.
     * @param depth the Follow Distance the relay built the graph at.
     * @param owners this device's accounts.
     */
    fun loose(
        saved: Set<String>,
        follows: Set<String>,
        counts: Map<String, Int>?,
        depth: Int?,
        owners: Set<String>,
        minFollowers: Int,
    ): Set<String> {
        val web = follows + owners
        if (saved.isEmpty() || follows.isEmpty()) return emptySet()
        if (depth != 3 || counts == null) return saved - web
        val bar = AccountWeb.bar(minFollowers)
        val outside = counts.filterKeys { it !in web }
        if (follows.size < bar) {
            // A new account's web is widened like the relay's newAccountWeb:
            // its top NEW_ACCOUNT_WEB_CAP are the web, the rest one hop out.
            val ranked = outside.entries.sortedWith(compareByDescending<Map.Entry<String, Int>> { it.value }.thenBy { it.key })
            return ranked.drop(NEW_ACCOUNT_WEB_CAP).mapTo(HashSet()) { it.key }
        }
        return outside.filterValues { it < bar }.keys
    }

    /** iOS `AccountWeb.newAccountWebCap`. */
    const val NEW_ACCOUNT_WEB_CAP = 1000

    /** [loose] lowercased with [web] taken out, saved that way so [Web] need not copy it on every filter. */
    fun cleanLoose(loose: Set<String>, web: Set<String>): Set<String> {
        val w = lowered(web)
        return lowered(loose).filterTo(HashSet()) { it !in w }
    }

    /** [keys] lowercased without "", and the same set back when it already is (no copy). */
    private fun lowered(keys: Set<String>): Set<String> =
        if ("" !in keys && keys.none { k -> k.any { it in 'A'..'Z' } }) keys
        else keys.mapTo(HashSet()) { it.lowercase() } - ""
}
