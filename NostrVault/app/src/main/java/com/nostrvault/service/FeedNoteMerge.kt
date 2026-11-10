package com.nostrvault.service

import com.nostrvault.data.model.FeedNote

/**
 * Adds a relay batch to the feed list in place of re-sorting the whole list.
 *
 * The result is exactly `(base + incoming).distinctBy { it.id }
 * .sortedByDescending { it.createdAt }.take(cap)`, the full sort this replaces:
 * the first copy of an id wins, and equal timestamps keep list order (what is
 * already in the feed first, then the batch in arrival order). The feed list
 * is always newest-first, so only the batch is sorted and then walked into it:
 * O(n + k log k) per batch instead of O(n log n) over up to 10,000 notes.
 * A base that is not newest-first falls back to the full sort.
 */
internal object FeedNoteMerge {
    fun mergeNewestFirst(base: List<FeedNote>, incoming: List<FeedNote>, cap: Int): List<FeedNote> {
        if (!isNewestFirst(base)) {
            val m = (base + incoming).distinctBy { it.id }.sortedByDescending { it.createdAt }
            return if (m.size > cap) m.take(cap) else m
        }
        val seen = HashSet<String>(base.size + incoming.size)
        for (note in base) seen.add(note.id)
        // Stable: equal timestamps keep arrival order, as in the full sort.
        val fresh = incoming.filter { seen.add(it.id) }.sortedByDescending { it.createdAt }
        val size = minOf(base.size + fresh.size, cap)
        val out = ArrayList<FeedNote>(size)
        var i = 0
        var j = 0
        while (out.size < size) {
            // Strictly newer only: on a tie the note already in the feed stays first.
            if (i >= base.size || (j < fresh.size && fresh[j].createdAt.time > base[i].createdAt.time)) {
                out.add(fresh[j++])
            } else {
                out.add(base[i++])
            }
        }
        return out
    }

    private fun isNewestFirst(notes: List<FeedNote>): Boolean {
        for (k in 1 until notes.size) {
            if (notes[k].createdAt.time > notes[k - 1].createdAt.time) return false
        }
        return true
    }
}
