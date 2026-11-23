package com.nostrvault.data.model

/**
 * Discovery design B, phone side: a desktop Vault fetches the recent posts
 * of each account's top 500 distant connections and hands them to the
 * phone's own feed store over the mesh (engine `trustrank.Distant`,
 * `copyv2_distant.go`). Discover asks that local store for the distant
 * people the reach bar lets in, highest score first, as many as the Vault
 * fetches for. External relays keep today's request. iOS
 * `Models/DistantPostAuthors.swift`.
 */
object DistantPostAuthors {
    /** The engine's `trustrank.DistantMax`: more would ask for people whose posts never reach the phone. */
    const val MAX = 500

    private val AUTHORS = Regex("\"authors\":\\[[^\\]]*\\]")

    /** [distant] ordered by score in [copy], highest first, ties by key, at most [MAX]. */
    fun pick(distant: Set<String>, copy: TrustRankCopy?): List<String> {
        if (copy == null || distant.isEmpty()) return emptyList()
        return distant.mapNotNull { pk -> copy.people[pk]?.let { pk to it.score } }
            .sortedWith(compareByDescending<Pair<String, Double>> { it.second }.thenBy { it.first })
            .take(MAX)
            .map { it.first }
    }

    /**
     * The second filter of Discover's request to the local feed store: [filter]
     * (kinds, since, limit, until) with its authors swapped for [authors]. Null
     * when there is nobody to ask for, or [filter] names no authors.
     */
    fun localFilter(filter: String, authors: List<String>): String? {
        if (authors.isEmpty() || !AUTHORS.containsMatchIn(filter)) return null
        val list = authors.joinToString(",") { "\"$it\"" }
        return AUTHORS.replaceFirst(filter, Regex.escapeReplacement("\"authors\":[$list]"))
    }
}
