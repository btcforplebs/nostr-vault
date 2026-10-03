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
