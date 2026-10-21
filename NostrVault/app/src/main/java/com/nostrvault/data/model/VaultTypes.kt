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

/** The "Vault" list's filters: everything, or only what you might answer. iOS `ActivityFilter`. */
enum class VaultActivityFilter {
    ALL,
    /** Replies, mentions and quotes. */
    MENTIONS;

    fun includes(kind: VaultActivity.Kind): Boolean = when (this) {
        ALL -> true
        MENTIONS -> kind == VaultActivity.Kind.REPLY || kind == VaultActivity.Kind.MENTION || kind == VaultActivity.Kind.QUOTE
    }
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

/**
 * The Vault tab's Zaps > Received list: who zapped which of my notes, and
 * when the newest zap on each landed. Pure so unit tests can pin it.
 */
object VaultZapsReceived {
    /** A parsed receipt and the receipt's own created_at. */
    data class Receipt(val parsed: ParsedZapReceipt, val receivedAt: Long)

    data class Result(
        /** Note id to (zapper, sats), in receipt order. */
        val zappers: Map<String, List<Pair<String, Long>>>,
        /** Note id to the newest zap's receipt time. */
        val lastZapAt: Map<String, Long>,
    )

    /**
     * The zapper is the zap request's signer ([ParsedZapReceipt.senderPubkey]),
     * never the receipt's pubkey (that's the wallet server). Zaps from someone
     * [isBlocked] are hidden, not dropped from the store: unblocking brings
     * them back on the next pass, as the Vault Activity list does. Sats
     * totals elsewhere still count them; this only shapes who-zapped-what.
     */
    fun build(
        receipts: List<Receipt>,
        myNoteIds: Set<String>,
        owner: String,
        isBlocked: (String) -> Boolean = { false },
        excludeOwner: Boolean = true,
    ): Result {
        val zappers = LinkedHashMap<String, MutableList<Pair<String, Long>>>()
        val lastZapAt = HashMap<String, Long>()
        for (receipt in receipts) {
            val parsed = receipt.parsed
            val targetId = parsed.targetNoteId ?: continue
            if (targetId !in myNoteIds) continue
            if (excludeOwner && parsed.senderPubkey == owner) continue
            if (isBlocked(parsed.senderPubkey)) continue
            zappers.getOrPut(targetId) { mutableListOf() }.add(parsed.senderPubkey to parsed.amountSats)
            lastZapAt[targetId] = maxOf(lastZapAt[targetId] ?: 0L, receipt.receivedAt)
        }
        return Result(zappers, lastZapAt)
    }
}
