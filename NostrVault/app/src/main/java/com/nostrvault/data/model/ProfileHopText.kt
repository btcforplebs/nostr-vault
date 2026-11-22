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
     * The hop to show. Rings 1 and 2 come from your follows and the Trust
     * Path, which follow an unfollow at once; the Haven's copy can be a day
     * old (Tron, #2419), so it only places people further out, and ring 2
     * only when the path cannot say (no names then). Null for you, for
     * someone the path finds outside your web, and for anyone neither knows.
     */
    fun hop(pubkey: String, me: String, path: TrustPath?, rank: TrustRankCopy.Person?): Int? {
        if (pubkey.equals(me, ignoreCase = true)) return null
        return when (path?.reach) {
            TrustPath.Reach.YOU -> null
            TrustPath.Reach.FOLLOW -> 1
            TrustPath.Reach.BRIDGED -> 2
            TrustPath.Reach.OUTSIDE -> rank?.hop?.takeIf { it >= 3 }
            TrustPath.Reach.WEB, TrustPath.Reach.UNKNOWN, null -> rank?.hop?.takeIf { it >= 2 }
        }
    }

    fun line(pubkey: String, me: String, path: TrustPath?, rank: TrustRankCopy.Person?, name: (String) -> String): String? {
        val hop = hop(pubkey, me, path, rank) ?: return null
        if (hop == 1) return "1 hop · you follow them"
        val followedBy = path?.takeIf { it.reach == TrustPath.Reach.BRIDGED }?.let { followedBy(it, name) }
        return if (followedBy == null) "$hop hops" else "$hop hops · $followedBy"
    }

    /**
     * "followed by Alice, Bob and 3 more". The number only when the path knows
     * every bridge ([TrustPath.exact], the links file); from relays it says
     * "and more", since their count is only a floor.
     */
    fun followedBy(path: TrustPath, name: (String) -> String): String? {
        val all = path.all.ifEmpty { path.bridges }
        if (all.isEmpty()) return null
        val names = all.take(NAMED).map(name)
        val rest = all.size - names.size
        return "followed by " + when {
            rest > 0 && path.exact -> names.joinToString(", ") + " and $rest more"
            rest > 0 || path.hasMore -> names.joinToString(", ") + " and more"
            else -> names.joinToString(" and ")
        }
    }
}
