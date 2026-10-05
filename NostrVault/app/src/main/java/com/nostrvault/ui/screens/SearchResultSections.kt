package com.nostrvault.ui.screens

import com.nostrvault.data.model.FeedNote

/** A link found in a note that matched the search. */
data class SearchLink(
    val url: String,
    /** The URL without its scheme, for the row's title. */
    val title: String,
    val noteId: String,
)

/**
 * The sections a search result list is built from, derived from what the
 * search returned: hashtags and links come out of the matching notes, the
 * same way the iPhone's SearchView builds them.
 */
object SearchResultSections {
    private val hashtagRegex = Regex("#(\\w+)")
    private val urlRegex = Regex("https?://\\S+")

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

    /**
     * Links the matching notes contain, in note order. A note that matches on
     * its text contributes its links even when the query is not in the URL.
     * Each URL is kept once: the list is keyed by URL.
     */
    fun links(notes: List<FeedNote>): List<SearchLink> {
        val seen = HashSet<String>()
        val links = ArrayList<SearchLink>()
        for (note in notes) {
            for (match in urlRegex.findAll(note.content)) {
                val url = match.value
                if (!seen.add(url)) continue
                links.add(
                    SearchLink(
                        url = url,
                        title = url.removePrefix("https://").removePrefix("http://"),
                        noteId = note.id,
                    ),
                )
            }
        }
        return links
    }

    /** Whether the section for [section] is drawn under [filter]. */
    fun shows(filter: SearchResultFilter, section: SearchResultFilter): Boolean =
        filter == SearchResultFilter.ALL || filter == section
}
