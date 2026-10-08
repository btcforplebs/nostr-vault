package com.nostrvault.service

import com.nostrvault.relay.HavenBridge

/**
 * Port of ContactManager.swift -- pure contact list management logic.
 * No networking, no UI. Operates on tag lists and pubkey sets.
 */
object ContactManager {

    sealed class FollowActionError : Exception() {
        data object ContactsNotLoaded : FollowActionError()
        /**
         * The load finished without the real list (timeout, error, relays that
         * never answered). Publishing now would replace the user's follows
         * with whatever is in memory, possibly nothing.
         */
        data object ListUnavailable : FollowActionError()
        data object AlreadyFollowing : FollowActionError()
        data object CannotUnfollowSelf : FollowActionError()
    }

    data class ContactListResult(
        val pTags: List<List<String>>,
        val pubkeys: List<String>,
        val relayPTagCount: Int,
    )

    data class FollowResult(
        val pTags: List<List<String>>,
        val pubkeys: List<String>,
    )

    /**
     * Parse a kind-3 contact list event's p-tags into the canonical follow set.
     * Ensures the owner and whitelisted accounts are included.
     */
    fun parseContactList(
        pTags: List<List<String>>,
        ownerHex: String,
        whitelistedNpubs: List<String>,
    ): ContactListResult {
        val relayCount = pTags.size
        val finalPTags = pTags.toMutableList()
        val existingPubkeys = pTags.mapNotNull { if (it.size >= 2) it[1] else null }.toSet()

        // Ensure owner is in the list
        if (ownerHex !in existingPubkeys) {
            finalPTags.add(listOf("p", ownerHex))
        }

        // Auto-follow whitelisted accounts. These are stored as npubs and the
        // follow set is hex, so each one has to be decoded — this loop used to
        // do nothing at all, which meant a whitelisted account was never
        // actually added to the contact list it was whitelisted for.
        for (npub in whitelistedNpubs) {
            val hex = HavenBridge.decodeNpub(npub.trim()) ?: continue
            if (hex !in existingPubkeys && finalPTags.none { it.size >= 2 && it[1] == hex }) {
                finalPTags.add(listOf("p", hex))
            }
        }

        val pubkeys = finalPTags.mapNotNull { if (it.size >= 2) it[1] else null }
        return ContactListResult(finalPTags, pubkeys, relayCount)
    }

    /**
     * Whether the user's real follow list is known: a kind 3 came back, or
     * every relay answered (EOSE) with none, i.e. a genuinely new account.
     * Follow / unfollow and queued taps publish only when this is true
     * (parity with iOS #180).
     */
    fun mayPublishFollowList(hasAttemptedLoad: Boolean, isLoading: Boolean, listConfirmed: Boolean): Boolean =
        hasAttemptedLoad && !isLoading && listConfirmed

    /** True when a list was found, or when every relay asked answered with none. */
    fun loadConfirmsList(foundList: Boolean, relaysAsked: Int, relaysAnswered: Int): Boolean =
        foundList || (relaysAsked > 0 && relaysAnswered >= relaysAsked)

    /**
     * Which relays finished answering one follow-list request: each relay once,
     * and only for the subscription id it was sent. A relay repeating EOSE must
     * not stand in for the relay that holds the list.
     */
    class EOSETally {
        private val subIds = mutableMapOf<String, String>()
        private val _answered = mutableSetOf<String>()
        val answered: Set<String> get() = _answered

        @Synchronized fun sent(subId: String, relay: String) { subIds[relay] = subId }
        @Synchronized fun eose(relay: String, subId: String) {
            if (subIds[relay] == subId) _answered.add(relay)
        }
        @Synchronized fun isAnswer(relay: String, subId: String): Boolean = subIds[relay] == subId
        @Synchronized fun answeredCount(): Int = _answered.size
    }

    // ── New account ───────────────────────────────────────────────

    /**
     * The starter-pack npubs that setup used to write into `whitelistedNpubs`
     * when someone tapped "Follow" on the Discover Accounts step. That list is
     * the user's own accounts, so each pick turned up in the account switcher
     * and nobody was followed. These are the npubs as they shipped (bfca0d16
     * and earlier), most of them the wrong people, which is why they are
     * listed here rather than read from the current file. Same list as iOS.
     */
    val starterNpubsSetupAddedAsAccounts: Set<String> = setOf(
        "npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m", // jack
        "npub1cn4t4cd78nm900qc2hhqte5aa8c9njm6qkfzw95tszufwcwtcnsq7g3vle", // "nvk"
        "npub1az9xj85cmxv8e9j9y80lvqp97crsqdu2fpu3srwthd99qfu9qsgstam8y8", // "LynAlden"
        "npub1gdu7w6l6w65qhrdeaf6eyywepwe7v7ezqtugsrxy7hl7ypjsvxksd76nak", // "ODELL"
        "npub1s33sw46p7vpsmak6v8j4x2naxqvqgv5xpep0lmllz9lxm7qds8gs8r5n32", // "MartyBent"
        "npub1l2vyh47mk2p0qlsku7hg0vn29faehy9hy34ygaclpn66ukqp3afqutajft", // "fiatjaf"
        "npub1jlrs53pkdfjnts29kveljul2sm0actt6n8dxrrzqcersttvcuv3qdjynqn", // "jb55"
        "npub12vkcxr0luzwp8e673v29eqjhrr7p9vqq8asav85swaepclllj09sylpugg", // "miljan"
        "npub1gcxzte5zlkncx26j68ez60fzkvtkm9e0vrwdcvsjakxf9mu9qewqlfnj5z", // vitor
        "npub1wjwj5r9ytyhgg7nwmy75t8pqzn7xapg5c5k0q8q9qqk9f1vvv4qsvvxs2w", // "Snowden"
        "npub1wmr34t36fy03m8hvgl96zl3znndyzyaqhwmwdtshwmtkg03fetaqhjg240", // "saylor"
        "npub1xnf02f60r9v0e5kty33a404dm79zr7z2eepyrk5gsq3m7pwvsz2sazlpr5", // "gladstein"
        "npub1h8nk2346qezka5cpm8jjh3yl5j88pf4ly2ptu7s6uu55wcfqy0wq36rpev", // "carla"
        "npub1qny3tkh0acurzla8x3zy4nhrjz5zd8l9sy9jys09umwng00manysew95gx", // "preston"
        "npub1hu3hdctm5nkzd8gslnyedfr5ddz3z547jqcl5j88g4fame2jd08qh6h8nh", // "walker"
    )

    /**
     * [accounts] minus the starter-pack npubs setup added by mistake. An entry
     * is kept if this device can sign for it ([canSign]): someone who really
     * added one of these people as an account did so with their key.
     */
    fun accountsWithoutStarterPackPicks(accounts: List<String>, canSign: (String) -> Boolean): List<String> =
        accounts.filter { entry ->
            val npub = entry.trim()
            npub !in starterNpubsSetupAddedAsAccounts || canSign(npub)
        }

    /**
     * Validate and perform a follow operation on the tag list.
     */
    fun prepareFollow(
        pubkey: String,
        currentPTags: List<List<String>>,
        currentPubkeys: List<String>,
        hasAttemptedLoad: Boolean,
        isLoading: Boolean,
        listConfirmed: Boolean,
    ): Result<FollowResult> {
        if (!hasAttemptedLoad || isLoading) {
            return Result.failure(FollowActionError.ContactsNotLoaded)
        }
        if (!listConfirmed) {
            return Result.failure(FollowActionError.ListUnavailable)
        }
        if (pubkey in currentPubkeys) {
            return Result.failure(FollowActionError.AlreadyFollowing)
        }
        val newPTags = currentPTags + listOf(listOf("p", pubkey))
        val newPubkeys = currentPubkeys + pubkey
        return Result.success(FollowResult(newPTags, newPubkeys))
    }

    /**
     * Validate and perform an unfollow operation on the tag list.
     */
    fun prepareUnfollow(
        pubkey: String,
        activeAccountHex: String,
        currentPTags: List<List<String>>,
        currentPubkeys: List<String>,
        hasAttemptedLoad: Boolean,
        isLoading: Boolean,
        listConfirmed: Boolean,
    ): Result<FollowResult> {
        if (!hasAttemptedLoad || isLoading) {
            return Result.failure(FollowActionError.ContactsNotLoaded)
        }
        if (!listConfirmed) {
            return Result.failure(FollowActionError.ListUnavailable)
        }
        if (pubkey == activeAccountHex) {
            return Result.failure(FollowActionError.CannotUnfollowSelf)
        }
        val newPTags = currentPTags.filter { !(it.size >= 2 && it[1] == pubkey) }
        val newPubkeys = currentPubkeys.filter { it != pubkey }
        return Result.success(FollowResult(newPTags, newPubkeys))
    }

    /**
     * Returns true if publishing should be BLOCKED because the contact list
     * would shrink drastically (prevents accidental wipes from stale data).
     */
    fun shouldBlockPublish(currentTagCount: Int, lastFetchedCount: Int): Boolean {
        if (lastFetchedCount <= 10) return false
        val ratio = currentTagCount.toDouble() / lastFetchedCount.toDouble()
        return ratio < 0.5
    }

    /**
     * Count mutual follows from a kind-3 event's tags, excluding the user's own follows.
     */
    fun countMutualFollows(
        eventTags: List<List<String>>,
        excludeSet: Set<String>,
    ): Map<String, Int> {
        val counts = mutableMapOf<String, Int>()
        for (tag in eventTags) {
            if (tag.size >= 2 && tag[0] == "p") {
                val pk = tag[1]
                if (pk !in excludeSet) {
                    counts[pk] = (counts[pk] ?: 0) + 1
                }
            }
        }
        return counts
    }

    /**
     * Rank pubkeys by mutual-follow count and return the top results.
     *
     * The order is total — ties break on the pubkey — because it is truncated.
     * Most of the second hop is followed by exactly one or two of your follows,
     * so [maxResults] almost always cuts through the middle of a large tie
     * group, and ordering on the count alone let map iteration order decide who
     * was inside it. Mirrors iOS `ContactManager.rankExtendedNetwork`.
     */
    fun rankExtendedNetwork(
        mutualCounts: Map<String, Int>,
        maxResults: Int = 500,
    ): List<String> =
        mutualCounts.entries
            .sortedWith(compareByDescending<Map.Entry<String, Int>> { it.value }.thenBy { it.key })
            .take(maxResults)
            .map { it.key }
}
