package com.nostrvault.setup

import com.nostrvault.vaultguide.VaultMeter

/**
 * The scan-join people step asks for 5 follows (the referrer and 4 of their
 * people) before setup goes on, so nobody joins by scan with 1 to 4 follows
 * and lands on the guide's # step (Logen 2026-11-26). When fewer people are
 * offered than that (their people didn't load), all of them is enough.
 * iOS twin: the same rule on the referrer step.
 */
object ReferrerFollowGate {
    /** Follows the step needs: 5, or the referrer plus everyone offered when that is fewer. */
    fun needed(offered: Int): Int = minOf(VaultMeter.GOAL, 1 + offered)

    /** The referrer counts as one. */
    fun count(ticked: Int): Int = 1 + ticked

    fun canFollow(ticked: Int, offered: Int): Boolean = count(ticked) >= needed(offered)

    /** "Only follow <name>" is offered only when 5 can't be reached anyway. */
    fun offersReferrerOnly(offered: Int): Boolean = 1 + offered < VaultMeter.GOAL

    /** The Follow button: how many it follows, or how many more to pick. */
    fun buttonText(ticked: Int, offered: Int): String {
        val count = count(ticked)
        val missing = needed(offered) - count
        return when {
            missing > 0 -> if (missing == 1) "Pick 1 more person" else "Pick $missing more people"
            count == 1 -> "Follow 1 person"
            else -> "Follow $count people"
        }
    }
}
