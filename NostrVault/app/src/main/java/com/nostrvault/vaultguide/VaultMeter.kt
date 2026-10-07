package com.nostrvault.vaultguide

import com.nostrvault.tutorials.TutorialStatus
import com.nostrvault.tutorials.TutorialStore

/**
 * The "Fill your vault" meter: how far a new account is toward a web of trust.
 * iOS: VaultMeter.swift. Keep the two in step.
 *
 * It reads the follow list itself, never taps made inside the guide, so a
 * follow from a profile, search or thread counts the same, and an unfollow
 * takes a slot back. 5 follows completes the guide; 10 makes the owner a
 * Vault Master, which is kept once earned (see [VaultMasterStore]).
 */
data class VaultMeter(
    /** People followed, not counting the owner. */
    val count: Int,
    /** The most recent follows, newest last, at most [MASTER_GOAL]. */
    val recent: List<String>,
    val stage: Stage,
) {
    enum class Stage { FILLING, FILLED, MASTER }

    /** Filled slots in the row being shown: the first 5 until the vault is filled, then all 10. */
    val slots: Int get() = if (stage == Stage.FILLING) GOAL else MASTER_GOAL

    /** "3 of 5", "7 of 10". Capped at the row's size. */
    val progressText: String get() = "${minOf(count, slots)} of $slots"

    /** The short form for the largest text sizes: "3/5". */
    val compactProgressText: String get() = "${minOf(count, slots)}/$slots"

    /** Read by TalkBack for the whole meter. */
    val accessibilityText: String
        get() {
            val n = minOf(count, slots)
            val people = if (n == 1) "person" else "people"
            return if (stage == Stage.MASTER) "Vault Master. $n of $slots $people followed."
            else "$n of $slots $people followed."
        }

    companion object {
        /** Follows that complete the guide. */
        const val GOAL = 5
        /** Follows that earn Vault Master. */
        const val MASTER_GOAL = 10

        /**
         * @param follows the contact list in its stored order (newest last).
         * @param owner the account's own hex pubkey, which is not a follow.
         * @param masterEarned whether this account has reached 10 before.
         */
        fun of(follows: List<String>, owner: String, masterEarned: Boolean): VaultMeter {
            val seen = HashSet<String>()
            val people = follows.filter { it != owner && it.isNotEmpty() && seen.add(it) }
            val stage = when {
                masterEarned || people.size >= MASTER_GOAL -> Stage.MASTER
                people.size >= GOAL -> Stage.FILLED
                else -> Stage.FILLING
            }
            return VaultMeter(people.size, people.takeLast(MASTER_GOAL), stage)
        }

        /**
         * An account that already follows this many never sees the guide: it
         * is marked finished straight away, because page tutorials only start
         * once Fill your vault is finished or skipped.
         */
        fun skipsGuide(followCount: Int): Boolean = followCount >= GOAL
    }
}

/**
 * Remembers, per account, that Vault Master was reached, so the gold meter is a
 * lasting mark and the bolt plays exactly once.
 */
class VaultMasterStore(private val store: TutorialStore) {
    private fun key(owner: String) = "vaultMaster.earned.$owner"

    fun isEarned(owner: String): Boolean = owner.isNotEmpty() && store.getString(key(owner)) == "1"

    /** Returns true only on the call that first reaches Vault Master. */
    fun record(meter: VaultMeter, owner: String): Boolean {
        if (owner.isEmpty() || meter.count < VaultMeter.MASTER_GOAL || isEarned(owner)) return false
        store.putString(key(owner), "1")
        return true
    }
}

/** When "Fill your vault" starts, finishes or is skipped. iOS: FillYourVaultRule. */
object FillYourVaultRule {
    enum class Action { NONE, START, FINISH_SILENTLY, FINISH }

    /**
     * What to do after the follow list changes.
     *
     * @param listKnown the real follow list has loaded. Before that the count
     *   reads 0 for everyone, and deciding then would show the guide to people
     *   who follow hundreds.
     * @param previousCount the count before this change, null for the first known list.
     */
    fun onFollowsChanged(
        listKnown: Boolean,
        previousCount: Int?,
        count: Int,
        status: TutorialStatus,
        isActive: Boolean,
    ): Action {
        if (!listKnown) return Action.NONE
        if (isActive) {
            // Only crossing 5 finishes it. A replay opened at 7 stays open.
            return if (previousCount != null && previousCount < VaultMeter.GOAL && count >= VaultMeter.GOAL) {
                Action.FINISH
            } else {
                Action.NONE
            }
        }
        if (status != TutorialStatus.NOT_STARTED) return Action.NONE
        return if (VaultMeter.skipsGuide(count)) Action.FINISH_SILENTLY else Action.START
    }

    /** Closing by hand: done past 5, so a replay closed at 7 stays done. */
    fun onClose(count: Int): TutorialStatus =
        if (count >= VaultMeter.GOAL) TutorialStatus.DONE else TutorialStatus.SKIPPED
}
