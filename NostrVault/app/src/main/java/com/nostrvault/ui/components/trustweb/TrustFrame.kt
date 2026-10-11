package com.nostrvault.ui.components

import com.nostrvault.data.model.TrustMap
import com.nostrvault.data.model.TrustPath

/**
 * One globe: who is at the core and what we know about their follows.
 */
internal data class TrustFrame(
    val center: String,
    /** Everyone [center] follows: the stars on the inner sphere. */
    val ring: List<String>,
    /**
     * False when no relay had [center]'s follow list, so the empty sphere
     * means "unknown", not "follows no one".
     */
    val listFound: Boolean,
    val path: TrustPath,
    /** Every bridge found so far, sorted; starts as the card's 5. */
    val bridges: List<String> = path.bridges,
    /** Signers whose lists already came back, so a batch skips them. */
    val seen: Set<String> = path.bridges.toSet(),
    /**
     * Relays answered with nothing new: the count is the whole count. The card
     * asks for one more list than it shows, so no extra means it has everyone.
     */
    val exhausted: Boolean = !path.hasMore,
    /** 3-hop routes once "look deeper" ran; null before. */
    val chains: List<TrustMap.Chain>? = null,
    val ringSet: Set<String> = ring.toSet(),
) {
    /**
     * The same frame around a new follow list: the bridges, the lists already
     * read and the deeper chains it had found stay (iOS TrustWebView keeps
     * them too), so a follow or unfollow doesn't throw the search away.
     */
    fun withRing(ring: List<String>, listFound: Boolean = true): TrustFrame =
        copy(ring = ring, listFound = listFound, ringSet = ring.toSet())
}
