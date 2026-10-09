package com.nostrvault.data.model

/**
 * Type definitions for the Vault / Relay tab, mirroring iOS VaultTypes.swift.
 */

enum class VaultViewMode(val displayName: String) {
    NOTES("Notes"),
    LIKES("Likes"),
    ZAPS("Zaps"),
    FOLLOWERS("Followers"),
}

/** Whitelisted notes already show in All, so it has no filter of its own (iOS #135). */
enum class VaultContentFilter(val displayName: String) {
    ALL("All"),
    MINE("Mine"),
    TAGGED("Mentions"),
    /**
     * Replies to your posts from people outside your Web of Trust. The relay
     * lets these in (anyone may reply to you); they are kept out of All and
     * Mentions and listed here instead (iOS #271).
     */
    OUTSIDE("Outside");

    companion object {
        /**
         * Whether a note tagging you comes from outside your network. The one
         * rule shared by the Notes filter and a notification tap's routing.
         * An empty graph (not built yet) counts nobody as outside.
         */
        fun isOutside(author: String, owner: String, whitelist: Set<String>, trusted: Set<String>): Boolean =
            author != owner && author !in whitelist && trusted.isNotEmpty() && author !in trusted
    }
}

/** Received = reactions others left on my notes; Given = notes I reacted to. */
enum class VaultLikesFilter(val displayName: String) {
    ON_MY_NOTES("Received"),
    MY_LIKES("Given"),
}

/** Received = zaps on my notes; Given = notes I zapped. */
enum class VaultZapsFilter(val displayName: String) {
    ON_MY_NOTES("Received"),
    MY_ZAPS("Given"),
}

/** Followers from the relay's follower ledger, spam left out: the latest ones, or everyone. */
enum class VaultFollowersFilter(val displayName: String) {
    NEW("New"),
    ALL("All"),
}

data class ParsedZapReceipt(
    val senderPubkey: String,
    val targetNoteId: String?,
    val amountSats: Long,
    /**
     * The zap request inside the receipt carries a valid signature. Anyone can
     * publish a receipt naming you as the sender; only a signed request proves
     * you made the zap.
     */
    val requestIsSigned: Boolean,
)
