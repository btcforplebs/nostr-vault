package com.nostrvault.data.model

/**
 * NIP-10: which event a note answers, read from its `e` tags. The Swift twin is
 * HavenApp/HavenApp/Models/NIP10Thread.swift; keep the rules identical.
 *
 * - An `e` tag marked "reply" names the parent.
 * - Failing that, one marked "root" does: a direct reply to the root.
 * - Unmarked tags are the deprecated positional form, where the last one is
 *   the parent.
 * - A tag marked "mention" is a quote, never a parent. Treating it as one hung
 *   every quote under the note it quotes, and a reply that also quoted
 *   something came out as a reply to the quote, because the mention is usually
 *   the last `e` tag.
 */
object NIP10Thread {
    /** NIP-22 comment kind. Replies to notes are moving to it (NIP PR #2447),
     *  and Amethyst, Ditto, Coracle and Snort already send it. */
    const val COMMENT_KIND = 1111

    /**
     * A NIP-22 comment (kind 1111) names its parent in its lowercase `e` tag
     * and its root in the uppercase `E`. Its `e` tags carry the parent's pubkey
     * in the fourth slot, not a marker, so the NIP-10 reading below would get
     * them wrong. A comment whose parent is not an event (an `a` or `i`
     * target) has no parent id.
     */
    fun parentEventId(kind: Int, tags: List<List<String>>): String? {
        if (kind == COMMENT_KIND) {
            return tags.firstOrNull { it.size >= 2 && it[0] == "e" }?.get(1)
        }
        val eTags = tags.filter { it.size >= 2 && it[0] == "e" }
        eTags.firstOrNull { marker(it) == "reply" }?.let { return it[1] }
        eTags.firstOrNull { marker(it) == "root" }?.let { return it[1] }
        return eTags.lastOrNull { marker(it) != "mention" }?.get(1)
    }

    /**
     * The thread root this note hangs under, or null if the note has none and
     * is a root itself. NIP-22 names it in the uppercase `E`; NIP-10 in the
     * tag marked "root", or the first non-mention `e` in the positional form.
     */
    fun rootEventId(kind: Int, tags: List<List<String>>): String? {
        if (kind == COMMENT_KIND) {
            return tags.firstOrNull { it.size >= 2 && it[0] == "E" }?.get(1)
        }
        val eTags = tags.filter { it.size >= 2 && it[0] == "e" && marker(it) != "mention" }
        return (eTags.firstOrNull { marker(it) == "root" } ?: eTags.firstOrNull())?.get(1)
    }

    /**
     * True for a comment that belongs to a kind 1 note thread (root kind `K`
     * is 1). Comments on videos, articles and other kinds are not conversation
     * the feed knows how to show.
     */
    fun isNoteComment(kind: Int, tags: List<List<String>>): Boolean =
        kind == COMMENT_KIND && tags.any { it.size >= 2 && it[0] == "K" && it[1] == "1" }

    /**
     * The kind a response to [parentKind] is sent as. A comment answers a
     * comment. Kind 1 replies are only valid onto a kind 1 parent (NIP-10),
     * so anything else — an article, a video, a picture — gets a comment.
     * Onto a kind 1 note it's a kind 1 reply by default (what most clients
     * show under a note today); [asComment] sends a comment instead, which
     * the composer offers on an original note.
     */
    fun replyKind(parentKind: Int, asComment: Boolean = false): Int = when (parentKind) {
        COMMENT_KIND -> COMMENT_KIND
        1 -> if (asComment) COMMENT_KIND else 1
        else -> COMMENT_KIND
    }

    /** True for a kind 1 note that isn't itself a reply: the one place the
     *  composer offers a choice between a reply and a comment. */
    fun isOriginalNote(kind: Int, tags: List<List<String>>): Boolean =
        kind == 1 && parentEventId(kind, tags) == null

    /** The `a`/`A` coordinate of an addressable (30000–39999) or replaceable
     *  (0, 3, 10000–19999) event; replaceables keep the trailing colon. */
    fun coordinate(kind: Int, pubkey: String, tags: List<List<String>>): String? = when {
        kind in 30000..39999 -> tags.firstOrNull { it.size >= 2 && it[0] == "d" }?.get(1)?.let { "$kind:$pubkey:$it" }
        kind == 0 || kind == 3 || kind in 10000..19999 -> "$kind:$pubkey:"
        else -> null
    }

    /**
     * NIP-22 tags for a top-level comment on the parent, which is also the
     * root: `E` for a regular event; `A` alone for an addressable or
     * replaceable one, with the parent named by `a` and this version's `e`.
     */
    fun topLevelCommentTags(
        parentId: String,
        parentKind: Int,
        parentPubkey: String,
        parentTags: List<List<String>>,
        relayHint: String
    ): List<List<String>> {
        val tags = mutableListOf<List<String>>()
        val coord = coordinate(parentKind, parentPubkey, parentTags)
        if (coord != null) {
            tags.add(listOf("A", coord, relayHint))
            tags.add(listOf("K", parentKind.toString()))
            tags.add(listOf("P", parentPubkey))
            tags.add(listOf("a", coord, relayHint))
            tags.add(listOf("e", parentId, relayHint, parentPubkey))
        } else {
            tags.add(listOf("E", parentId, relayHint, parentPubkey))
            tags.add(listOf("K", parentKind.toString()))
            tags.add(listOf("P", parentPubkey))
            tags.add(listOf("e", parentId, relayHint, parentPubkey))
        }
        tags.add(listOf("k", parentKind.toString()))
        tags.add(listOf("p", parentPubkey))
        return tags
    }

    /** NIP-22 tags for any comment: on a comment it copies that comment's
     *  root and points at it; on anything else the parent is the root. */
    fun commentTags(
        parentId: String,
        parentKind: Int,
        parentPubkey: String,
        parentTags: List<List<String>>,
        relayHint: String
    ): List<List<String>> =
        if (parentKind == COMMENT_KIND) commentReplyTags(parentId, parentPubkey, parentTags, relayHint)
        else topLevelCommentTags(parentId, parentKind, parentPubkey, parentTags, relayHint)

    /**
     * NIP-22 tags for a comment answering the comment `parent`: the root scope
     * (`E`/`A`/`I`, `K`, `P`) is copied from the parent unchanged, and the
     * parent itself goes in `e`, `k`, `p`.
     */
    fun commentReplyTags(
        parentId: String,
        parentPubkey: String,
        parentTags: List<List<String>>,
        relayHint: String
    ): List<List<String>> {
        val tags = parentTags.filter { it.size >= 2 && it[0] in setOf("E", "A", "I", "K", "P") }.toMutableList()
        tags.add(listOf("e", parentId, relayHint, parentPubkey))
        tags.add(listOf("k", COMMENT_KIND.toString()))
        tags.add(listOf("p", parentPubkey))
        return tags
    }

    private fun marker(tag: List<String>): String = if (tag.size >= 4) tag[3] else ""
}
