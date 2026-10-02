package com.nostrvault.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * One owner's followers from the relay's follower ledger (Go `GetFollowersC`).
 * The relay already sorts them newest follow first and puts each in a tier.
 * Port of iOS `FollowerSnapshot` (VaultFollowers.swift, PR #136).
 */
@Serializable
data class FollowerSnapshot(
    val counts: Counts,
    val followers: List<Entry>? = null,
) {
    @Serializable
    data class Counts(
        val trusted: Int = 0,
        val others: Int = 0,
        val spam: Int = 0,
        val unfollowed: Int = 0,
    ) {
        /** The one count the list shows. Spam is left out on purpose. */
        val total: Int get() = trusted + others
    }

    @Serializable
    data class Entry(
        val pubkey: String,
        val tier: String = "",
        val following: Boolean = false,
        /** Followed before the ledger started: not news. */
        val existing: Boolean = false,
        @SerialName("followed_at") val followedAt: Long = 0,
        /** Follow starts we saw; more than one means they left and came back. */
        val follows: Int = 0,
        /** Their latest list time: the only "when" for a follow that predates the ledger. */
        @SerialName("list_at") val listAt: Long = 0,
    ) {
        val isSpam: Boolean get() = tier == "spam"
        val isReturning: Boolean get() = follows > 1

        /**
         * A follow we watched happen: a first follow since the ledger began, or a
         * comeback. A refollow bot republishing its list is neither.
         */
        val isNews: Boolean get() = following && !isSpam && (!existing || isReturning)
    }

    /**
     * Current followers, spam left out: follows we watched happen (in the
     * relay's order, newest first), then everyone who followed before tracking
     * began, newest list first.
     */
    val current: List<Entry> by lazy {
        val current = followers.orEmpty().filter { it.following && !it.isSpam }
        val watched = current.filter { it.isNews }
        val earlier = current.filterNot { it.isNews }.sortedByDescending { it.listAt }
        watched + earlier
    }

    fun entries(filter: VaultFollowersFilter): List<Entry> = when (filter) {
        VaultFollowersFilter.NEW -> current.take(NEW_LIMIT)
        VaultFollowersFilter.ALL -> current
    }

    /** True when a follow we watched happen is newer than [seenAt] (epoch seconds): the red dot. */
    fun hasNewSince(seenAt: Long): Boolean =
        followers.orEmpty().any { it.isNews && it.followedAt > seenAt }

    companion object {
        const val NEW_LIMIT = 100

        private val json = Json { ignoreUnknownKeys = true }

        /** Null for `{"error": ...}` (relay stopped, ledger not open) or bad JSON. */
        fun parse(raw: String?): FollowerSnapshot? {
            if (raw.isNullOrBlank()) return null
            return runCatching { json.decodeFromString(serializer(), raw) }.getOrNull()
        }
    }
}
