package com.nostrvault.ui.components

import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.PeopleSearchRank
import com.nostrvault.data.model.TrustMap
import com.nostrvault.data.model.TrustRankCopy

/** Rows the WOT tab's Find someone shows. */
internal const val FIND_SOMEONE_LIMIT = 8

/**
 * The WOT tab's Find someone over the profiles already cached, in the shared
 * people order ([PeopleSearchRank], the Search tab's too), blocked people left
 * out. Instant, so it runs every keystroke. iOS `TrustWebView+Search.searchMatches`.
 * Each hit carries its row tag: You follow, In your web (3+ steps too), or none.
 */
internal fun findSomeone(
    query: String,
    profiles: Collection<FeedProfile>,
    me: String,
    follows: Set<String>,
    web: Set<String>,
    copy: TrustRankCopy?,
    blocked: Set<String>,
    limit: Int = FIND_SOMEONE_LIMIT,
): List<TrustMap.PersonHit> {
    val circle = PeopleSearchRank.Circle(own = setOf(me), follows = follows, web = web, copy = copy)
    return PeopleSearchRank.rank(profiles, query, circle, blocked = blocked, limit = limit, person = PeopleSearchRank::person)
        .map { TrustMap.PersonHit(it.pubkey, rowTier(it.pubkey, circle)) }
}

/** A pasted key's row tag, with the same circle rules. */
internal fun rowTier(pubkey: String, circle: PeopleSearchRank.Circle): TrustMap.Tier = when (PeopleSearchRank.tier(pubkey, circle)) {
    PeopleSearchRank.Tier.FOLLOW -> TrustMap.Tier.FOLLOW
    PeopleSearchRank.Tier.WEB, PeopleSearchRank.Tier.FURTHER -> TrustMap.Tier.WEB
    else -> TrustMap.Tier.OTHER
}
