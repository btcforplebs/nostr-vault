package com.nostrvault.data.model

/**
 * Replies fetched for Threaded View on Popular and Global. Popular is a ranked
 * list of top-level posts, and Global's stream rarely carries the replies to
 * the posts it shows, so a threaded card there had nothing under it. FeedService
 * asks the relays for the replies to the posts on screen, and the feed groups
 * them under their post. Pure, so the rules are pinned by unit tests. iOS:
 * `FeedService.loadFeedThreadReplies` (#250, ddeab490).
 */
object FeedThreadReplies {
    /** Post ids per REQ; relays cap filter size. */
    const val CHUNK = 50

    /** Replies asked for per chunk. */
    const val LIMIT = 500

    const val TIMEOUT_MS = 6_000L

    /** The feeds whose replies are fetched rather than taken from the stream. */
    fun fetchesReplies(mode: FeedMode): Boolean =
        mode == FeedMode.POPULAR || mode == FeedMode.GLOBAL

    /** Kind 1 replies tagging any of [postIds]. */
    fun filter(postIds: List<String>): String =
        """{"kinds":[1],"#e":[${postIds.joinToString(",") { "\"$it\"" }}],"limit":$LIMIT}"""

    /**
     * A real reply into one of [roots]: its NIP-10 root is one of them, or,
     * with no root named, its parent is. A note that merely tags a post (a
     * reply elsewhere that quotes it) would open a stray thread of its own.
     */
    fun isInThread(kind: Int, tags: List<List<String>>, roots: Set<String>): Boolean {
        NIP10Thread.rootEventId(kind, tags)?.let { return it in roots }
        return NIP10Thread.parentEventId(kind, tags)?.let { it in roots } ?: false
    }

    /**
     * Whether a fetched reply is kept: not a blocked person's, not spam, a
     * real reply into [roots], and, on Global, inside [trusted]. Global's
     * replies pass the same trust rule as its posts, or a trusted post would
     * carry the open firehose in underneath it. Null [trusted] is everyone
     * (Popular, or Global's shield on Everyone); an empty set admits nobody,
     * failing closed like the Global feed.
     */
    fun admits(
        note: FeedNote,
        roots: Set<String>,
        blocked: Set<String>,
        trusted: Set<String>?,
    ): Boolean =
        note.pubkey !in blocked &&
            (trusted == null || note.pubkey in trusted) &&
            !note.isNoiseOrSpam() &&
            isInThread(note.kind, note.tags, roots)

    /**
     * The feed's [posts] followed by the fetched [replies] that hang into one
     * of them. Replies to a post no longer in the list (blocked since, or
     * dropped by a trust switch) stay out rather than opening a card with no
     * root, as do replies the stream already delivered and anyone blocked
     * after the fetch.
     */
    fun attach(posts: List<FeedNote>, replies: Collection<FeedNote>, blocked: Set<String>): List<FeedNote> {
        if (replies.isEmpty()) return posts
        val ids = posts.mapTo(HashSet()) { it.id }
        val extra = replies.filter {
            it.id !in ids && it.pubkey !in blocked && isInThread(it.kind, it.tags, ids)
        }
        return if (extra.isEmpty()) posts else posts + extra
    }
}
