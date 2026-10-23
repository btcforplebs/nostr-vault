package com.nostrvault.data.model

/**
 * One reply in the thread view's full mode, flattened so each reply is its
 * own lazy list row instead of a whole subtree drawn as one item.
 */
data class ThreadReplyRow(
    val note: FeedNote,
    /** 1 for a direct reply to the note being read, 2 for a reply to that, and so on. */
    val depth: Int,
    /** The first reply shown under its parent: the connector line starts here. */
    val isFirstChild: Boolean,
    /**
     * Depth of the row below, 0 when this is the last row. Connector lines
     * deeper than it end at this row.
     */
    val nextDepth: Int,
    /**
     * Replies under this one left out because it sits at
     * [ThreadReplyRows.COLLAPSE_DEPTH]: the row shows a "Show N more" pill.
     */
    val collapsedReplies: Int,
) {
    val id: String get() = note.id
}

/**
 * Builds the thread view's reply rows. Pure, so the tree is worked out once
 * per reply list (a map of children, not a filter of every reply per node)
 * and pinned by unit tests.
 */
object ThreadReplyRows {

    /** Replies this deep show a pill instead of their own replies (iOS ThreadedReplyNode). */
    const val COLLAPSE_DEPTH = 3

    /** Each note's replies among [pool], in pool order. */
    fun children(pool: List<FeedNote>): Map<String, List<FeedNote>> {
        val out = HashMap<String, MutableList<FeedNote>>()
        for (note in pool) note.parentEventId?.let { out.getOrPut(it) { mutableListOf() }.add(note) }
        return out
    }

    /** How many replies each note has among [pool]. */
    fun replyCounts(pool: List<FeedNote>): Map<String, Int> = children(pool).mapValues { it.value.size }

    /**
     * Every reply under [targetId] in reading order: direct replies oldest
     * first, each followed by its own replies in pool order, down to
     * [COLLAPSE_DEPTH]. Cycle-safe.
     */
    fun build(targetId: String, pool: List<FeedNote>): List<ThreadReplyRow> {
        val children = children(pool)
        val flat = mutableListOf<ThreadReplyRow>()
        val seen = mutableSetOf(targetId)
        fun visit(note: FeedNote, depth: Int, isFirstChild: Boolean): Boolean {
            if (!seen.add(note.id)) return false
            val kids = children[note.id].orEmpty()
            val collapsed = if (depth >= COLLAPSE_DEPTH) kids.size else 0
            flat.add(ThreadReplyRow(note, depth, isFirstChild, nextDepth = 0, collapsedReplies = collapsed))
            if (collapsed == 0) {
                var first = true
                for (kid in kids) if (visit(kid, depth + 1, first)) first = false
            }
            return true
        }
        var first = true
        for (reply in children[targetId].orEmpty().sortedBy { it.createdAt }) {
            if (visit(reply, 1, first)) first = false
        }
        return flat.mapIndexed { i, row -> row.copy(nextDepth = flat.getOrNull(i + 1)?.depth ?: 0) }
    }
}
