package com.nostrvault.service

import com.nostrvault.data.model.GlobalSearchResults

/**
 * Search never puts someone you blocked in front of you: not their profile,
 * not a note that shows them (author, reposter, reposted author, parent), and
 * so not the links and hashtags those notes carry. Results are only hidden,
 * so unblocking brings them back on the next search (iOS SearchBlockFilter).
 */
object SearchBlockFilter {

    fun apply(
        results: GlobalSearchResults,
        blocked: Set<String>,
        authorOf: (String) -> String? = { null },
    ): GlobalSearchResults {
        if (blocked.isEmpty()) return results
        return GlobalSearchResults(
            profiles = results.profiles.filter { it.pubkey !in blocked },
            notes = results.notes.filter { !FeedFilterEngine.involvesBlocked(it, blocked, authorOf) },
        )
    }

    /** Suggested-profile candidates with blocked people taken out, order kept. */
    fun visiblePubkeys(pubkeys: List<String>, blocked: Set<String>): List<String> =
        if (blocked.isEmpty()) pubkeys else pubkeys.filter { it !in blocked }
}
