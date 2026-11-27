package com.nostrvault.data.model

/**
 * The Search tab's order (search plan §1a, §1b): people by [PeopleSearchRank],
 * notes by closeness tier then newest, with people 3+ steps away (the Haven's
 * rank copy) counted inside your web. Then split by your web: people and notes
 * from outside fold under "N from outside your web" (Logen 2026-11-13 option
 * B; an exact name outside stays in the fold, 5d1ce4cb #1).
 * iOS: `SearchView+Search.filteredResults`.
 */
object SearchResultsOrder {
    /** What the screen shows, and what folds away under one line. */
    data class Split(
        val inside: GlobalSearchResults = GlobalSearchResults(),
        val outside: GlobalSearchResults = GlobalSearchResults(),
    ) {
        val outsideCount: Int get() = outside.profiles.size + outside.notes.size
    }

    /** In the rank copy at all: placed by the Haven, so not outside (Logen 5d1ce4cb #6; iOS A3). */
    fun distant(circle: PeopleSearchRank.Circle): (String) -> Boolean =
        { pubkey -> circle.copy?.get(pubkey) != null }

    fun apply(results: GlobalSearchResults, query: String, circle: PeopleSearchRank.Circle): Split {
        // A search relay matched some people on its own index: keep them, last in their tier.
        val (insidePeople, outsidePeople) =
            PeopleSearchRank.split(results.profiles, query, circle, keepUnmatched = true, person = PeopleSearchRank::person)
        val distant = distant(circle)
        val (insideNotes, outsideNotes) = SearchRanking.rankNotes(results.notes, circle.own, circle.follows, circle.web, distant)
            .partition { SearchRanking.tier(it.pubkey, circle.own, circle.follows, circle.web, distant) < SearchRanking.OUTSIDE_TIER }
        return Split(GlobalSearchResults(insidePeople, insideNotes), GlobalSearchResults(outsidePeople, outsideNotes))
    }

    /**
     * The fold opens by itself when the only exact name match is in it: they
     * stay in the fold, but it is who you typed (Logen 5d1ce4cb #1).
     */
    fun opensItself(split: Split, query: String): Boolean =
        PeopleSearchRank.outsideHoldsTheOnlyExactMatch(split.inside.profiles, split.outside.profiles, query, PeopleSearchRank::person)
}
