package com.nostrvault.data.model

/**
 * How a NIP-84 highlight (kind 9802) names what it was taken from. Pure, so
 * the feed card and the tests share one copy. iOS: `FeedHighlight`.
 */
object FeedHighlight {
    /** NIP-84 highlight: a passage someone marked in an article or page. */
    const val KIND = 9802

    /**
     * The highlighted event: its `a` coordinate (an article) in [QuoteRef]'s
     * spelling, else its `e` id. Drawn as a quote card under the passage, so
     * it is fetched and opened like any quote.
     */
    fun sourceReference(tags: List<List<String>>): String? {
        tags.firstOrNull { it.size >= 2 && it[0] == "a" }?.get(1)?.let {
            return QuoteRef.COORDINATE_PREFIX + it
        }
        return tags.firstOrNull { it.size >= 2 && it[0] == "e" }?.get(1)
    }

    /** A web page the passage came from, when it came from no event. */
    fun sourceURL(tags: List<List<String>>): String? {
        if (sourceReference(tags) != null) return null
        val value = tags.firstOrNull { it.size >= 2 && it[0] == "r" }?.get(1) ?: return null
        return value.takeIf { it.startsWith("https://") || it.startsWith("http://") }
    }

    /** What the highlighter wrote about the passage (NIP-84 quote highlight). */
    fun comment(tags: List<List<String>>): String? =
        tags.firstOrNull { it.size >= 2 && it[0] == "comment" }?.get(1)?.trim()?.takeIf { it.isNotEmpty() }
}
