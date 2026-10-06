package com.nostrvault.service

/**
 * Hashtags to suggest on an empty Hashtags feed: the ones the people you
 * follow use most. Pure, so it is tested without a relay.
 */
object HashtagSuggestions {
    const val MAX_SUGGESTIONS = 8

    /**
     * The most used `t` tags across [notesTags] (one entry per note, its
     * tags), lowercased with any leading '#' stripped, leaving out [followed].
     * A note counts once per tag however often it repeats it. Ranked by count,
     * ties alphabetically, at most [limit].
     */
    fun top(
        notesTags: List<List<List<String>>>,
        followed: Collection<String>,
        limit: Int = MAX_SUGGESTIONS,
    ): List<String> {
        val exclude = followed.map(InterestList::normalize).toSet()
        val counts = HashMap<String, Int>()
        for (tags in notesTags) {
            val names = tags.asSequence()
                .filter { it.size >= 2 && it[0] == "t" }
                .map { InterestList.normalize(it[1]) }
                .filter { it.isNotEmpty() && it !in exclude }
                .toSet()
            for (name in names) counts[name] = (counts[name] ?: 0) + 1
        }
        return counts.entries
            .sortedWith(compareByDescending<Map.Entry<String, Int>> { it.value }.thenBy { it.key })
            .take(limit)
            .map { it.key }
    }
}
