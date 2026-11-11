package com.nostrvault.ui.theme

/**
 * How many lines of a post's text Threaded View's lines show, from the Feed
 * Text settings. Mirrors iOS CondensedNoteLine.bodyLineLimit.
 */
data class FeedLineLimits(
    private val threaded: Int = DEFAULT_THREADED,
) {
    /**
     * The old (compact, threaded) pair. Compact View is gone, so the first
     * value is ignored; only MainActivity still passes it, until the
     * in-flight change there lands and this goes too.
     */
    constructor(@Suppress("UNUSED_PARAMETER") retiredCompact: Int, threaded: Int) : this(threaded)

    /** Lines per line in Threaded View: the root gets the setting, replies one fewer. */
    fun threadedLines(isRoot: Boolean): Int {
        val root = threaded.coerceIn(RANGE)
        return if (isRoot) root else maxOf(1, root - 1)
    }

    companion object {
        const val DEFAULT_THREADED = 5
        val RANGE = 1..12
    }
}
