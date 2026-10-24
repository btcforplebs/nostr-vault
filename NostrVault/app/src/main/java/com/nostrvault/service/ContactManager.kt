package com.nostrvault.service

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
     * Parse a kind-3 contact list event's p-tags into the follow set: exactly
     * the 64-hex `p` tags the list holds, nothing added. This used to add the
     * owner and every device-wide whitelisted account, so the next follow or
     * unfollow on any account published a list that followed your other
     * accounts too. Feeds that should show your own posts read
     * [FeedService.feedAuthorSet], not this.
     */
    fun parseContactList(pTags: List<List<String>>): ContactListResult {
        // Only `p` tags naming a 64-hex key are follows. A kind 3 can also
        // carry `t`, `a` and other tags (Amethyst writes hashtag follows);
        // reading element [1] of those made "bitcoin" a followed "pubkey".
        val followTags = pTags.filter { isFollowTag(it) }
        val pubkeys = followTags.map { it[1] }.distinct()
        return ContactListResult(followTags, pubkeys, followTags.size)
    }

    /**
     * [local] without the entries an older build added on its own: [added]
     * (you and your other device accounts) unless the relay copy
     * [relayPubkeys] really follows them. Used before re-publishing a cached
     * list, which can predate the parse fix.
     */
    fun withoutAddedAccounts(local: List<String>, relayPubkeys: Collection<String>, added: Set<String>): List<String> {
        val onRelay = relayPubkeys.toHashSet()
        return local.filter { it !in added || it in onRelay }
    }

    private val hexKey = Regex("^[0-9a-f]{64}$")

    /** A `p` tag whose value is a 64-hex pubkey. */
    fun isFollowTag(tag: List<String>): Boolean =
        tag.size >= 2 && tag[0] == "p" && hexKey.matches(tag[1])

    /**
     * The tags to publish for [pubkeys], given the [loadedTags] of the list
     * they came from: every tag that is not a follow (`t`, `a`, ...) is kept
     * where it was, a follow that stays keeps its own tag (relay hint,
     * petname), and new follows go at the end. A `p` tag without a 64-hex
     * value is dropped: it is not a follow, and an older build wrote those.
     */
    fun contactListTags(pubkeys: List<String>, loadedTags: List<List<String>>): List<List<String>> {
        val wanted = pubkeys.toSet()
        val placed = mutableSetOf<String>()
        val tags = mutableListOf<List<String>>()
        for (tag in loadedTags) {
            when {
                tag.isEmpty() -> Unit
                tag[0] != "p" -> tags.add(tag)
                isFollowTag(tag) && tag[1] in wanted && placed.add(tag[1]) -> tags.add(tag)
            }
        }
        for (pk in pubkeys) if (placed.add(pk)) tags.add(listOf("p", pk))
        return tags
    }

    /**
     * How long to wait before signing a follow list so its created_at (the
     * signer's current second) is later than [lastCreatedAt], the newest list
     * signed or loaded. Two lists in one second tie, relays keep the lower id,
     * and the follows in the other one vanish. A clock more than [maxWaitMs]
     * behind is not waited out.
     */
    fun followListSignDelayMs(nowMs: Long, lastCreatedAt: Long, maxWaitMs: Long = 3_000): Long {
        val wait = (lastCreatedAt + 1) * 1000 - nowMs
        return if (wait <= 0 || wait > maxWaitMs) 0 else wait
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
     * The self-heal re-publish of the local list over an older relay copy.
     * Never an empty list, and never one under half a relay copy of more than
     * 10: one tap changes one follow, so a local list that much smaller is a
     * stale or partly loaded one, and publishing it would wipe follows.
     */
    fun mayRepublish(localSize: Int, relaySize: Int): Boolean =
        localSize > 0 && (relaySize <= 10 || localSize * 2 >= relaySize)

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
