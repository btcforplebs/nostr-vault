package com.nostrvault.ui.screens.feed

import com.nostrvault.data.model.FeedThread

/**
 * The post you were reading when the feed layout switched, so the new layout
 * can open on it. iOS `FeedView.topVisibleNoteId` / `rowId(showing:)` (PR #130).
 *
 * Expanded and condensed list notes keyed by note id; threaded lists cards
 * keyed by thread root. [noteIds] is the row's note first, then — for a
 * thread card — its other notes in reading order, any of which can stand in
 * for the card in a flat layout.
 */
data class FeedLayoutAnchor(val noteIds: List<String>) {

    /** Row index of the anchor among flat [noteIds] (expanded / condensed), or null. */
    fun indexInNotes(notes: List<String>): Int? {
        if (noteIds.isEmpty()) return null
        val index = HashMap<String, Int>(notes.size)
        notes.forEachIndexed { i, id -> index.putIfAbsent(id, i) }
        return noteIds.firstNotNullOfOrNull { index[it] }
    }

    /** Row index of the thread card that holds the anchor, or null. */
    fun indexInThreads(threads: List<FeedThread>): Int? {
        for (id in noteIds) {
            val i = threads.indexOfFirst { thread ->
                thread.rootId == id || thread.entries.any { it.note.id == id }
            }
            if (i >= 0) return i
        }
        return null
    }

    companion object {
        /** A note row in the expanded or condensed layout. */
        fun note(noteId: String) = FeedLayoutAnchor(listOf(noteId))

        /** A thread card: its root, then the notes it shows, in reading order. */
        fun thread(thread: FeedThread) = FeedLayoutAnchor(
            (listOf(thread.rootId) + thread.entries.map { it.note.id }).distinct(),
        )

        /**
         * The topmost row a reader is looking at: the first one with at
         * least [minVisiblePercent] of its height below the top of the list's
         * content area (rows under the translucent toolbar have offsets below
         * zero). [rows] are (index, offset, size) of the visible rows, in order.
         */
        fun topRowIndex(rows: List<Triple<Int, Int, Int>>, minVisiblePercent: Int = 30): Int? {
            val row = rows.firstOrNull { (_, offset, size) ->
                size > 0 && (offset + size).toLong() * 100 >= size.toLong() * minVisiblePercent
            } ?: rows.firstOrNull()
            return row?.first
        }
    }
}
