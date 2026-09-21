package com.nostrvault.data.model

/**
 * How a timeline feed draws its rows. One control cycles through these in
 * order, so the three layouts are one setting rather than three toggles.
 * Mirrors iOS `FeedLayoutMode.swift`.
 */
enum class FeedLayoutMode {
    /** Full note cards: media, actions, engagement. */
    EXPANDED,

    /** One note per line: avatar, name, three lines of text, a media thumbnail. */
    CONDENSED,

    /** Condensed lines grouped into whole conversations, root plus replies. */
    THREADED;

    /**
     * The next layout in the cycle. Feeds that cannot be threaded (grids and
     * card lists) skip straight back to expanded.
     */
    fun next(supportsThreading: Boolean): FeedLayoutMode = when (this) {
        EXPANDED -> CONDENSED
        CONDENSED -> if (supportsThreading) THREADED else EXPANDED
        THREADED -> EXPANDED
    }

    /**
     * Threading only makes sense on a timeline of notes; a media grid or an
     * article list has no replies to gather.
     */
    fun clamped(supportsThreading: Boolean): FeedLayoutMode =
        if (this == THREADED && !supportsThreading) CONDENSED else this

    /** True when rows draw as condensed lines — both condensed layouts do. */
    val usesCondensedRows: Boolean get() = this != EXPANDED

    val storageKey: String
        get() = when (this) {
            EXPANDED -> "expanded"
            CONDENSED -> "condensed"
            THREADED -> "threaded"
        }

    val displayName: String
        get() = when (this) {
            EXPANDED -> "Expanded View"
            CONDENSED -> "Compact View"
            THREADED -> "Threaded View"
        }

    /**
     * What tapping the control will switch to, so the button can say where it
     * goes rather than only where it is.
     */
    fun nextDisplayName(supportsThreading: Boolean): String =
        next(supportsThreading).displayName

    companion object {
        fun fromStorageKey(key: String?): FeedLayoutMode? =
            entries.firstOrNull { it.storageKey == key }

        /**
         * Resolve the stored layout for a feed, falling back to the per-feed
         * compact-mode boolean that shipped before this setting existed.
         * Without this, everyone who had chosen compact mode would silently
         * be reset to expanded on upgrade.
         *
         * @param storedLayout `feedLayoutModes[feed]`, once the user has cycled.
         * @param storedCompact the legacy `feedCompactModes[feed]` override.
         * @param defaultCompact this feed's built-in compact default.
         */
        fun resolve(
            storedLayout: String?,
            storedCompact: Boolean?,
            defaultCompact: Boolean,
        ): FeedLayoutMode {
            fromStorageKey(storedLayout)?.let { return it }
            return if (storedCompact ?: defaultCompact) CONDENSED else EXPANDED
        }
    }
}
