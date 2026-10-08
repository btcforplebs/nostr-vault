package com.nostrvault.ui.screens

/**
 * The Media tab's type filter as a set, as on iOS (`MediaTypeFilter`
 * selection): any mix of Photo, Video, GIF and Other, where the full set is
 * "All". [MediaTypeFilter.ALL] is never stored; it stands for the full set.
 * The composer's relay picker reads and writes the same setting.
 */
object MediaTypeSelection {
    /** iOS `MediaTypeFilter.storageKey`. Comma-joined, in [TYPES] order. */
    const val STORAGE_KEY = "mediaGallery.typeFilter"

    val TYPES: List<MediaTypeFilter> =
        listOf(MediaTypeFilter.PHOTO, MediaTypeFilter.VIDEO, MediaTypeFilter.GIF, MediaTypeFilter.OTHER)

    val ALL: Set<MediaTypeFilter> = TYPES.toSet()

    /** The one type [item] counts as: a GIF first, then photo or video; audio and the rest are Other. */
    fun category(item: BlossomMediaItem): MediaTypeFilter = when {
        item.isGif -> MediaTypeFilter.GIF
        item.isImage -> MediaTypeFilter.PHOTO
        item.isVideo -> MediaTypeFilter.VIDEO
        else -> MediaTypeFilter.OTHER
    }

    fun matches(selection: Set<MediaTypeFilter>, item: BlossomMediaItem): Boolean = category(item) in selection

    fun isAll(selection: Set<MediaTypeFilter>): Boolean = selection.containsAll(ALL)

    /** Whether [filter]'s button shows as on. All is on only when everything is. */
    fun isOn(selection: Set<MediaTypeFilter>, filter: MediaTypeFilter): Boolean =
        if (filter == MediaTypeFilter.ALL) isAll(selection) else filter in selection

    /**
     * iOS `toggleMediaTypeFilter`: All selects everything. From everything, a
     * type narrows to just that type. Otherwise a type toggles, but the last
     * one left cannot be turned off.
     */
    fun tap(selection: Set<MediaTypeFilter>, filter: MediaTypeFilter): Set<MediaTypeFilter> = when {
        filter == MediaTypeFilter.ALL -> ALL
        isAll(selection) -> setOf(filter)
        filter in selection -> if (selection.size > 1) selection - filter else selection
        else -> selection + filter
    }

    fun toKey(selection: Set<MediaTypeFilter>): String =
        TYPES.filter { it in selection }.joinToString(",") { it.name.lowercase() }

    /** Empty or unreadable means everything, as iOS `selection(from:)`. */
    fun fromKey(raw: String?): Set<MediaTypeFilter> {
        val parsed = raw.orEmpty().split(',').mapNotNull { name ->
            TYPES.firstOrNull { it.name.equals(name.trim(), ignoreCase = true) }
        }.toSet()
        return parsed.ifEmpty { ALL }
    }
}
