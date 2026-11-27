package com.nostrvault.vaultguide

import com.nostrvault.tutorials.TutorialStore

/**
 * The hard 5-follow rule for new accounts (Logen 2026-11-27, fc2719f6): a
 * key made by "New to Nostr" on this device can't finish, skip or hide the
 * "Fill your feed" guide until it follows 5 people, on every path (scan-join
 * at 1-4 → Discover, skip-referrer → topics). Skip, "Not now" and "Hide the
 * meter" are gone while it is locked, and the meter says how many are left.
 *
 * Only keys setup marks here are held: an account someone signed in with, or
 * any account from before this rule, keeps the old way out.
 * iOS: FillYourFeedGate.swift.
 */
object FillYourFeedGate {
    /** Locked while a new account is short of 5 (and never built its web of trust). */
    fun isLocked(required: Boolean, meter: VaultMeter): Boolean =
        required && meter.stage == VaultMeter.Stage.FILLING

    /** Follows still needed, 0 once there. */
    fun left(meter: VaultMeter): Int = maxOf(0, VaultMeter.GOAL - meter.count)

    /** The meter's second line while locked: "Follow 3 more to finish". */
    fun leftText(meter: VaultMeter): String {
        val n = left(meter)
        return if (n == 1) "Follow 1 more to finish" else "Follow $n more to finish"
    }
}

/** Per account: whether setup made this key here, so the 5-follow rule holds. */
class FillYourFeedGateStore(private val store: TutorialStore) {
    private fun key(account: String) = "fillYourFeed.required.$account"

    fun isRequired(account: String): Boolean = account.isNotEmpty() && store.getString(key(account)) == "1"

    fun require(account: String) {
        if (account.isNotEmpty()) store.putString(key(account), "1")
    }
}
