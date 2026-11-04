package com.nostrvault.data.model

/**
 * The one web-of-trust rule for other people's replies, comments, chat and
 * reactions (Logen 2026-11-04, twin of iOS `TrustGate.swift`).
 *
 * Someone passes when they are in [always] (you, the note's author, a
 * stream's host) or in your web. [trusted] is
 * [com.nostrvault.service.FeedService.globalTrustSet]: null means the shield
 * is set to Everyone, so everyone passes. An empty set means the web hasn't
 * loaded: like Global, it fails closed and only [always] passes.
 */
object TrustGate {

    fun allows(author: String, trusted: Set<String>?, always: Set<String>): Boolean =
        trusted == null || author in always || author in trusted

    /** [items] split into (inside your web, outside it), order kept. */
    fun <T> split(items: List<T>, trusted: Set<String>?, always: Set<String>, author: (T) -> String): Pair<List<T>, List<T>> =
        if (trusted == null) items to emptyList()
        else items.partition { allows(author(it), trusted, always) }

    /**
     * A thread's replies split for the "Outside your web" fold. A stranger's
     * reply goes in the fold with everything under it, so an answer to it is
     * never shown without the reply it answers.
     */
    fun splitThread(
        replies: List<FeedNote>,
        trusted: Set<String>?,
        always: Set<String>,
    ): Pair<List<FeedNote>, List<FeedNote>> {
        if (trusted == null) return replies to emptyList()
        val byId = replies.associateBy { it.id }
        val outside = HashMap<String, Boolean>()
        fun isOutside(note: FeedNote, depth: Int): Boolean = outside.getOrPut(note.id) {
            if (!allows(note.pubkey, trusted, always)) true
            else if (depth > replies.size) false // cycle guard
            else note.parentEventId?.let { byId[it] }?.let { isOutside(it, depth + 1) } ?: false
        }
        return replies.partition { !isOutside(it, 0) }
    }

    /** A repost passes only when both the reposter and the reposted note's author do. */
    fun allowsRepost(reposter: String, originalAuthor: String?, trusted: Set<String>?, always: Set<String>): Boolean =
        allows(reposter, trusted, always) && (originalAuthor == null || allows(originalAuthor, trusted, always))

    const val OUTSIDE_TITLE = "Outside your web"

    /** The fold's line: "3 replies from outside your web". */
    fun foldLabel(count: Int, noun: String = "reply", plural: String = "replies"): String =
        "$count ${if (count == 1) noun else plural} from outside your web"
}
