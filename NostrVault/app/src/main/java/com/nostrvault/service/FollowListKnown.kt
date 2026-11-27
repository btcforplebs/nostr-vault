package com.nostrvault.service

/**
 * When the follow list (kind 3) is known well enough to edit (Logen 2026-11-27, b6e725ef). Same rule as web
 * follows.js followListKnown and iOS (Tory, nv-apple):
 *  - only the account's own relays (its kind 10002) count, never the app's defaults or an indexer. One exception: a
 *    relay list that names exactly one relay counts purplepag.es ([INDEXER]) as a second own relay, so that relay and
 *    the indexer must both answer (Logen 2026-11-27, b219c87b; web the same). Two or more own relays: own only;
 *  - an own relay that is down drops out of the count: only a connect that failed at the socket, or a hold such a
 *    failure started ([com.nostrvault.data.remote.WebSocketClient.downAtConnect]), so a second follow inside the hold
 *    counts as the first did. A connect timeout, a 429, a blocked or held-for-429 relay, and one that connected but
 *    sent no EOSE in time still count against: each may hold a newer copy (Tom/Tron, web PR 2611);
 *  - at least 2 own relays must answer, always;
 *  - a list found: more than half of the own relays not down answered;
 *  - no list found: every own relay answered, down ones too (one that didn't may hold the only copy, and a first list
 *    sent to it would replace it: Tron, PR 2611), no copy was skipped for being dated ahead, and every other relay
 *    asked that wasn't down answered too (it may hold the list).
 * Before: more than half of all own relays, so 3 dead of 7 left one slow relay between a follow and a refusal
 * (rd 2026-11-27). Other lists keep [ListMerge.unknownWhy].
 */
internal object FollowListKnown {
    /**
     * The rule on counts: [answered] own relays sent EOSE, [reached] of the [asked] own relays weren't down. [held]: no
     * copy on the relays but one is held here, which the relays not down must all confirm has nothing newer (#2612).
     */
    fun known(answered: Int, reached: Int, asked: Int, found: Boolean, held: Boolean = false): Boolean =
        answered >= 2 && when {
            found -> answered * 2 > reached
            held -> answered >= reached
            else -> answered >= asked
        }

    /**
     * Null: [lookup] lets a follow edit build on it ([found]: a copy is known, from the relays or held here).
     * Otherwise what to tell the person, as [ListMerge.unknownWhy].
     */
    fun unknownWhy(own: Collection<String>, lookup: NostrService.ReplaceableLookup, found: Boolean, held: Boolean = false): String? {
        val mine = counted(own)
        if (mine.isEmpty()) return ListMerge.NO_RELAY_LIST
        val answeredBy = lookup.answeredBy.map(ListMerge::key).toSet()
        val reachedBy = lookup.reachedBy?.map(ListMerge::key)?.toSet()?.plus(answeredBy)
        val answered = mine.count { it in answeredBy }
        val reached = if (reachedBy == null) mine.size else mine.count { it in reachedBy }
        if (!known(answered, reached, mine.size, found, held)) return ListMerge.NOT_ANSWERED
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
    fun confirmsNone(own: Collection<String>, lookup: NostrService.ReplaceableLookup, held: Boolean = false): Boolean =
        lookup.event == null && unknownWhy(own, lookup, found = false, held = held) == null

    /** "No list": none skipped for being ahead, and every relay asked that wasn't down answered. */
    private fun noneKnown(lookup: NostrService.ReplaceableLookup, answeredBy: Set<String>, reachedBy: Set<String>?): Boolean {
        if (lookup.event != null || lookup.ahead) return false
        // Not recorded: every relay asked must have answered, as before (confirmedNone).
        if (reachedBy == null) return lookup.confirmedNone
        return reachedBy.all { it in answeredBy }
    }
}
