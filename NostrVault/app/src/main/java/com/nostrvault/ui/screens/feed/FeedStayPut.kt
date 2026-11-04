package com.nostrvault.ui.screens.feed

/**
 * The Feed never moves the reader on its own (Logen 2026-11-04, iOS
 * `FeedStayPut`): with Auto-load on, new posts go in above while the reader
 * stays on the post they were reading, and an "N new above" pill takes them
 * up. Only at the top does the feed grow upward into view.
 */
internal object FeedStayPut {
    /**
     * Whether waiting posts go in by themselves now: Auto-load on, some
     * waiting, no load running, no tapped post on screen (posts added above
     * would push it off its landing line). Where the reader is doesn't matter.
     */
    fun autoLoads(enabled: Boolean, waiting: Int, isLoading: Boolean, postOpen: Boolean): Boolean =
        enabled && waiting > 0 && !isLoading && !postOpen

    /** Below the top, the row being read is held in place while posts go in above it. */
    fun keepsReading(isAtTop: Boolean): Boolean = !isAtTop

    /**
     * Where the held row [key] sits after posts went in: its new index, or
     * null when it left the list (a reload) or did not move.
     */
    fun heldIndex(keys: List<Any>, key: Any, oldIndex: Int): Int? {
        val index = keys.indexOf(key)
        return index.takeIf { it >= 0 && it != oldIndex }
    }

    /**
     * Rows above the reader that came in after the newest row they saw at the
     * top ([seenTop]): the "N new above" count. 0 at the top, or when that row
     * left the list (a reload or a feed switch starts over).
     */
    fun newAbove(keys: List<Any>, seenTop: Any?, firstVisible: Int): Int {
        if (seenTop == null || firstVisible <= 0) return 0
        val seenAt = keys.indexOf(seenTop)
        return if (seenAt <= 0) 0 else minOf(seenAt, firstVisible)
    }

    /** The pill's words: "1 new above", "12 new above". */
    fun aboveLabel(count: Int): String = "$count new above"
}
