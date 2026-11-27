package com.nostrvault.data.model

/**
 * The Search tab's order (search plan §1a, §1b): people by [PeopleSearchRank],
 * notes by closeness tier then newest, with people 3+ steps away (the Haven's
 * rank copy) counted inside your web. iOS: `SearchView+Search.filteredResults`.
 */
object SearchResultsOrder {
    /** In the rank copy at all: placed by the Haven, so not outside (Logen 5d1ce4cb #6; iOS A3). */
    fun distant(circle: PeopleSearchRank.Circle): (String) -> Boolean =
        { pubkey -> circle.copy?.get(pubkey) != null }

    fun apply(results: GlobalSearchResults, query: String, circle: PeopleSearchRank.Circle): GlobalSearchResults =
        GlobalSearchResults(
            // A search relay matched some people on its own index: keep them, last in their tier.
            profiles = PeopleSearchRank.rank(results.profiles, query, circle, keepUnmatched = true, person = PeopleSearchRank::person),
            notes = SearchRanking.rankNotes(results.notes, circle.own, circle.follows, circle.web, distant(circle)),
        )
}
