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
     * The kind a reply to [parentKind] is sent as. Replies match the thread:
     * answering a comment sends a comment, anything else stays kind 1, which
     * every client can show today. When the big clients render comments, flip
     * this to always return [COMMENT_KIND] for notes.
     */
    fun replyKind(parentKind: Int): Int = if (parentKind == COMMENT_KIND) COMMENT_KIND else 1

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
