package com.nostrvault.ui.screens.settings

/**
 * The one place a Follow Distance level becomes words (iOS
 * FollowDistanceWords). The stored level is what the relay runs (haven-go
 * pkg/wot/simple_in_memory.go): 1 = only you, 2 = the people you follow,
 * 3 = the people they follow too. A hop is one follow away from you and you
 * are never a hop, so the levels read "Only you", "1 hop" and "2 hops". The
 * stored value, WOT_DEPTH and the mesh's wot_depth keep the level; only the
 * screen converts.
 */
internal object FollowDistanceWords {
    /** How many follows away the level reaches. 0 is only you. */
    fun hops(level: Int): Int = RelayAccessLimits.clampedFollowDistance(level) - 1

    /** The stepper's value and the Vault settings row: "Only you", "1 hop", "2 hops". */
    fun short(level: Int): String = when (val n = hops(level)) {
        0 -> "Only you"
        1 -> "1 hop"
        else -> "$n hops"
    }

    /** The Vault tab's "Who can reach you" line. */
    fun reachDetail(level: Int): String =
        if (hops(level) == 0) "Only you. Everyone else is kept out."
        else "People within ${short(level)} of you. Everyone else is kept out."
}
