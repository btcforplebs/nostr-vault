package com.nostrvault.service

/**
 * Why a follow or unfollow wasn't published ([publishContactList]), so the pill can say the real reason instead of a
 * bare "Couldn't follow, try again" (rd, 2026-11-27: 3 of 7 own relays dead, every tap refused with no reason).
 * Same cases and words as iOS FollowPublishFailure (Tory, nv-apple 2026-11-27 10:19Z).
 */
sealed interface FollowPublishFailure {
    /** The account has no relay list (kind 10002), so it has no relays of its own to ask. */
    data object NoRelayList : FollowPublishFailure

    /** Only [answered] of the account's [own] write relays answered: the newest list can't be checked. */
    data class OwnRelaysShort(val answered: Int, val own: Int) : FollowPublishFailure

    /** Every own relay answered, yet not enough to know the list (fewer than two relays in all, or "none" unproven). */
    data object NotEnoughAnswered : FollowPublishFailure

    /** The signer returned nothing. */
    data object SignerDidNotSign : FollowPublishFailure

    /** No relay took the signed list (a refusal, a timeout, or no connection from each). */
    data object AllRefused : FollowPublishFailure

    companion object {
        /**
         * The failure when the newest list isn't known: [OwnRelaysShort] while some of the [own] relays didn't answer,
         * [NotEnoughAnswered] once all of them did. [answeredBy] is every relay that answered, null when the lookup
         * itself failed (none did).
         */
        fun notKnown(own: Collection<String>, answeredBy: Collection<String>?): FollowPublishFailure {
            val mine = own.map(ListMerge::key).toSet()
            if (mine.isEmpty()) return NoRelayList
            val answered = answeredBy.orEmpty().map(ListMerge::key).toSet().count { it in mine }
            return if (answered < mine.size) OwnRelaysShort(answered, mine.size) else NotEnoughAnswered
        }
    }
}

/** The pill for a follow ([follow]) or unfollow that wasn't published because of [failure]. */
internal fun followFailedMessage(follow: Boolean, failure: FollowPublishFailure? = null): String {
    val verb = if (follow) "follow" else "unfollow"
    return when (failure) {
        null -> "Couldn't $verb, try again"
        FollowPublishFailure.NoRelayList -> "Couldn't $verb. ${ListMerge.NO_RELAY_LIST}"
        is FollowPublishFailure.OwnRelaysShort ->
            "Couldn't $verb: only ${failure.answered} of your ${failure.own} relays answered, so your newest follow " +
                "list can't be checked. Nothing changed. Remove dead relays in Settings › Relays, then try again."
        FollowPublishFailure.NotEnoughAnswered ->
            "Couldn't $verb: not enough relays answered, so your newest follow list can't be checked. " +
                "Nothing changed. Try again in a moment."
        FollowPublishFailure.SignerDidNotSign ->
            "Couldn't $verb: your signer didn't sign it. Nothing changed. Check your signer, then try again."
        FollowPublishFailure.AllRefused ->
            "Couldn't $verb: every relay refused it. Nothing changed. Check your relays in Settings › Relays."
    }
}
