package com.nostrvault.data.model

/**
 * How a timeline feed draws its rows. The feed button toggles between the
 * two; feeds that cannot thread stay expanded. Compact View is gone (Logen,
 * 2026-11-11): a saved "condensed" reads back as expanded. Mirrors iOS
 * `FeedLayoutMode.swift`.
 */
enum class FeedLayoutMode {
    /** Full note cards: media, actions, engagement. Replies start off. */
    EXPANDED,

    /** Condensed lines grouped into whole conversations, root plus replies. Replies start on. */
    THREADED;

    /** The other layout. Feeds that cannot be threaded (grids and card lists) stay expanded. */
    fun next(supportsThreading: Boolean): FeedLayoutMode = when (this) {
        EXPANDED -> if (supportsThreading) THREADED else EXPANDED
        THREADED -> EXPANDED
    }

    /**
     * Threading only makes sense on a timeline of notes; a media grid or an
     * article list has no replies to gather.
     */
    fun clamped(supportsThreading: Boolean): FeedLayoutMode =
        if (this == THREADED && !supportsThreading) EXPANDED else this

    /** Whether the feed's Show replies goes on when the user switches to this layout. */
    val showsRepliesByDefault: Boolean get() = this == THREADED

    val storageKey: String
        get() = when (this) {
            EXPANDED -> "expanded"
            THREADED -> "threaded"
        }

    val displayName: String
        get() = when (this) {
            EXPANDED -> "Expanded View"
            THREADED -> "Threaded View"
        }

    /**
     * What tapping the control will switch to, so the button can say where it
     * goes rather than only where it is.
     */
    fun nextDisplayName(supportsThreading: Boolean): String =
        next(supportsThreading).displayName

    companion object {
        /** The retired Compact View's key, still found in older configs. */
        const val LEGACY_CONDENSED_KEY = "condensed"

        fun fromStorageKey(key: String?): FeedLayoutMode? =
            if (key == LEGACY_CONDENSED_KEY) EXPANDED else entries.firstOrNull { it.storageKey == key }

        /**
         * Resolve the stored layout for a feed (`feedLayoutModes[feed]`).
         * Nothing stored, an unknown value, and the legacy per-feed compact
         * boolean all read as expanded now that Compact View is gone.
         */
        fun resolve(storedLayout: String?): FeedLayoutMode = fromStorageKey(storedLayout) ?: EXPANDED

        /**
         * Rewrites saved "condensed" layouts to "expanded" and turns Show
         * replies off with them, since expanded starts with replies off.
         * Returns null when nothing was condensed, so it runs once.
         */
        fun migrateCondensed(layouts: Map<String, String>): Map<String, String>? {
            if (layouts.values.none { it == LEGACY_CONDENSED_KEY }) return null
            return layouts.mapValues { (_, v) -> if (v == LEGACY_CONDENSED_KEY) EXPANDED.storageKey else v }
        }
    }
}
