package com.nostrvault.ui.screens

/**
 * How the Media tab orders its items. Port of iOS `MediaSortOption`; the raw
 * [key] is what is stored, under the same name iOS uses.
 */
enum class MediaSortOption(val key: String, val label: String) {
    NEWEST_FIRST("newestFirst", "Newest first"),
    OLDEST_FIRST("oldestFirst", "Oldest first"),
    MEDIA_TYPE("mediaType", "Media type"),
    ON_RELAY_FIRST("onRelayFirst", "On relay first"),
    ;

    /**
     * Date headings only mean something when the list is ordered by date.
     * Under any other sort items from every month are interleaved.
     */
    val groupsByDate: Boolean get() = this == NEWEST_FIRST || this == OLDEST_FIRST

    /** Orders [items]. Every branch falls back to newest first so the order never shuffles. */
    fun sorted(items: List<BlossomMediaItem>): List<BlossomMediaItem> = when (this) {
        NEWEST_FIRST -> items.sortedByDescending { it.sortTime }
        OLDEST_FIRST -> items.sortedBy { it.sortTime }
        MEDIA_TYPE -> items.sortedWith(
            compareBy<BlossomMediaItem> { typeRank(it) }.thenByDescending { it.sortTime },
        )
        // On this phone's relay (the vault) ahead of files only on outside servers.
        ON_RELAY_FIRST -> items.sortedWith(
            compareBy<BlossomMediaItem> { if (it.isLocal) 0 else 1 }.thenByDescending { it.sortTime },
        )
    }

    companion object {
        const val STORAGE_KEY = "mediaGallery.sortOption"

        fun fromKey(key: String?): MediaSortOption = entries.firstOrNull { it.key == key } ?: NEWEST_FIRST

        /** Photos, then GIFs, videos, audio, anything else (iOS `typeRank`). */
        internal fun typeRank(item: BlossomMediaItem): Int = when {
            item.isGif -> 1
            item.isImage -> 0
            item.isVideo -> 2
            item.isAudio -> 3
            else -> 4
        }
    }
}
