package com.nostrvault.data.model

/**
 * The order hashtag results show in, in the Search tab and the Vault's search
 * (search plan §1c): the tag you typed first, then by how many of the matched
 * notes carry it, then A-Z. Pure. iOS twin: `Models/HashtagSearchRank.swift`
 * (A5); web: `net/search.js` hashtags.
 */
object HashtagSearchRank {
    private val spaces = Regex("\\s+")

    /** The words a query names tags by: lowercased, `#` dropped. */
    fun words(query: String): List<String> =
        query.lowercase().replace("#", " ").split(spaces).filter { it.isNotEmpty() }

    /** How many items carry each tag. [tags] gives one item's tags, lowercased; a tag twice on one item counts once. */
    fun <T> counts(items: Iterable<T>, tags: (T) -> Collection<String>): Map<String, Int> {
        val counts = HashMap<String, Int>()
        for (item in items) for (tag in tags(item).toSet()) counts[tag] = (counts[tag] ?: 0) + 1
        return counts
    }

    /**
     * [counts]' tags in order. Exact means the tag is the whole query or one
     * of its words ("#bitcoin" and "bitcoin" both make "bitcoin" exact).
     */
    fun order(counts: Map<String, Int>, query: String): List<String> {
        val words = words(query)
        val exact = words.toSet() + words.joinToString("")
        return counts.keys.sortedWith(
            compareBy<String> { it !in exact }
                .thenByDescending { counts[it] ?: 0 }
                .thenBy { it },
        )
    }
}
