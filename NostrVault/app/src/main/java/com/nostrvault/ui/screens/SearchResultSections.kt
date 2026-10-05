package com.nostrvault.ui.screens

import com.nostrvault.data.model.FeedNote

/**
 * The sections a search result list is built from, derived from what the
 * search returned: hashtags come out of the matching notes, the
 * same way the iPhone's SearchView builds them.
 */
object SearchResultSections {
    private val hashtagRegex = Regex("#(\\w+)")

    /**
     * Hashtags written in [notes] whose text contains [query] (lowercased,
     * de-duplicated, sorted). A leading '#' on the query is ignored, so
     * "#bit" finds #bitcoin too.
     */
    fun hashtags(notes: List<FeedNote>, query: String): List<String> {
        val needle = query.trim().lowercase().removePrefix("#")
        if (needle.isEmpty()) return emptyList()
        val found = HashSet<String>()
        for (note in notes) {
            for (match in hashtagRegex.findAll(note.content)) {
                val tag = match.groupValues[1].lowercase()
                if (tag.contains(needle)) found.add(tag)
            }
        }
        return found.sorted()
    }

    /** Whether the section for [section] is drawn under [filter]. */
    fun shows(filter: SearchResultFilter, section: SearchResultFilter): Boolean =
        filter == SearchResultFilter.ALL || filter == section
}
