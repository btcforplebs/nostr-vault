package com.nostrvault.service

/**
 * When the follow list (kind 3) is known well enough to edit (Logen 2026-11-27, b6e725ef). Same rule as web
 * follows.js followListKnown and iOS (Tory, nv-apple):
 *  - only the account's own relays (its kind 10002) count, never the app's defaults or an indexer. One exception: a
 *    relay list that names exactly one relay counts purplepag.es ([INDEXER]) as a second own relay, so that relay and
 *    the indexer must both answer (Logen 2026-11-27, b219c87b; web the same). Two or more own relays: own only;
 *  - an own relay that never connected drops out of the count. One that connected but sent no EOSE in time still
 *    counts against: it may hold a newer copy;
 *  - at least 2 own relays must answer, always;
 *  - a list found: more than half of the own relays that connected answered;
 *  - no list found: every own relay that connected answered, no copy was skipped for being dated ahead, and every
 *    other relay asked that connected answered too (it may hold the list).
 * Before: more than half of all own relays, so 3 dead of 7 left one slow relay between a follow and a refusal
 * (rd 2026-11-27). Other lists keep [ListMerge.unknownWhy].
 */
internal object FollowListKnown {
    /** The rule on counts: [answered] own relays sent EOSE, [reached] own relays connected. */
    fun known(answered: Int, reached: Int, found: Boolean): Boolean =
        answered >= 2 && (if (found) answered * 2 > reached else answered >= reached)

    /**
     * Null: [lookup] lets a follow edit build on it ([found]: a copy is known, from the relays or held here).
     * Otherwise what to tell the person, as [ListMerge.unknownWhy].
     */
    fun unknownWhy(own: Collection<String>, lookup: NostrService.ReplaceableLookup, found: Boolean): String? {
        val mine = counted(own)
        if (mine.isEmpty()) return ListMerge.NO_RELAY_LIST
        val answeredBy = lookup.answeredBy.map(ListMerge::key).toSet()
        val reachedBy = lookup.reachedBy?.map(ListMerge::key)?.toSet()?.plus(answeredBy)
        val answered = mine.count { it in answeredBy }
        val reached = if (reachedBy == null) mine.size else mine.count { it in reachedBy }
        if (!known(answered, reached, found)) return ListMerge.NOT_ANSWERED
        if (!found && !noneKnown(lookup, answeredBy, reachedBy)) return ListMerge.NOT_ANSWERED
        return null
    }

    /** purplepag.es: the second answer for a one-relay list ([counted]). */
    const val INDEXER = "wss://purplepag.es"

    /** The relays that count: [own], plus [INDEXER] when [own] names exactly one relay. */
    fun counted(own: Collection<String>): Set<String> {
        val mine = own.map(ListMerge::key).toSet()
        return if (mine.size == 1) mine + ListMerge.key(INDEXER) else mine
    }

    /** Where the follow lookup asks besides [alsoAsk]: [own], and [INDEXER] when it counts ([counted]). */
    fun askAlso(own: List<String>): List<String> =
        if (own.map(ListMerge::key).toSet().size == 1) own + INDEXER else own

    /**
     * Whether the relays confirm there is no list ([ContactManager.saveBase]'s confirmedNone): no list found by the
     * rule above, as [NostrService.ReplaceableLookup.confirmedNone] with relays that never connected left out.
     */
    fun confirmsNone(own: Collection<String>, lookup: NostrService.ReplaceableLookup): Boolean =
        lookup.event == null && unknownWhy(own, lookup, found = false) == null

    /** "No list": none skipped for being ahead, and every relay asked that connected answered. */
    private fun noneKnown(lookup: NostrService.ReplaceableLookup, answeredBy: Set<String>, reachedBy: Set<String>?): Boolean {
        if (lookup.event != null || lookup.ahead) return false
        // Not recorded: every relay asked must have answered, as before (confirmedNone).
        if (reachedBy == null) return lookup.confirmedNone
        return reachedBy.all { it in answeredBy }
    }
}
