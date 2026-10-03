package com.nostrvault.ui.theme

/**
 * How many lines of a post's text the condensed feed layouts show, from the
 * Feed Text settings. Mirrors iOS CondensedNoteLine.bodyLineLimit.
 */
data class FeedLineLimits(
    private val compact: Int = DEFAULT_COMPACT,
    private val threaded: Int = DEFAULT_THREADED,
) {
    /** Lines per row in Compact View. */
    val compactLines: Int get() = compact.coerceIn(RANGE)

    /** Lines per line in Threaded View: the root gets the setting, replies one fewer. */
    fun threadedLines(isRoot: Boolean): Int {
        val root = threaded.coerceIn(RANGE)
        return if (isRoot) root else maxOf(1, root - 1)
    }

    companion object {
        const val DEFAULT_COMPACT = 3
        const val DEFAULT_THREADED = 3
        val RANGE = 1..12
    }
}
