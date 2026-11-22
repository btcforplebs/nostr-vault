package com.nostrvault.data.model

/**
 * The line under a profile's name: how far they are from you, in true hops
 * at any distance (Logen 2026-11-22: "4 hops" for someone far out, up to 6),
 * and who you follow follows them. iOS twin to come
 * (`Views/Profile/ProfileHopLine.swift`).
 *
 * - "1 hop · you follow them"
 * - "2 hops · followed by Alice, Bob and 3 more"
 * - "4 hops"
 *
 * The hop comes from your follows and the people you follow (the Trust Path),
 * and past that from your Haven's rank ([TrustRankCopy]). With neither,
 * there is no line: nothing claims a distance it does not know.
 */
object ProfileHopText {
    /** Names shown before "and N more". */
    const val NAMED = 2

    /**
     * The hop to show: 1 for a follow, 2 when someone you follow follows them,
     * else the Haven's ring. Null for you, and for anyone neither knows.
     */
    fun hop(pubkey: String, me: String, path: TrustPath?, rank: TrustRankCopy.Person?): Int? {
        if (pubkey.equals(me, ignoreCase = true)) return null
        return when (path?.reach) {
            TrustPath.Reach.YOU -> null
            TrustPath.Reach.FOLLOW -> 1
            TrustPath.Reach.BRIDGED -> 2
            else -> rank?.hop
        }
    }

    fun line(pubkey: String, me: String, path: TrustPath?, rank: TrustRankCopy.Person?, name: (String) -> String): String? {
        val hop = hop(pubkey, me, path, rank) ?: return null
        val hops = if (hop == 1) "1 hop" else "$hop hops"
        if (hop == 1) return "$hops · you follow them"
        val followedBy = path?.takeIf { hop == 2 }?.let { followedBy(it, name) }
        return if (followedBy == null) hops else "$hops · $followedBy"
    }

    /**
     * "followed by Alice, Bob and 3 more". The count is exact when the path
     * came from the relay's links file (every bridge). From relays the list
     * stops once enough are found ([TrustPath.hasMore] past
     * [TrustPath.LISTS_PER_FILTER]), so then it says "and more".
     */
    fun followedBy(path: TrustPath, name: (String) -> String): String? {
        val all = path.all.ifEmpty { path.bridges }
        if (all.isEmpty()) return null
        val names = all.take(NAMED).map(name)
        val rest = all.size - names.size
        val capped = path.hasMore && all.size <= TrustPath.LISTS_PER_FILTER
        return "followed by " + when {
            capped -> names.joinToString(", ") + " and more"
            rest > 0 -> names.joinToString(", ") + " and $rest more"
            else -> names.joinToString(" and ")
        }
    }
}
