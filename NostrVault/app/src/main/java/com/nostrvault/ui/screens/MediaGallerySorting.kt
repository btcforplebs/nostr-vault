package com.nostrvault.ui.screens

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.TextStyle
import java.time.temporal.WeekFields
import java.util.Locale

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

/** One run of consecutive items under the same heading; [startIndex] is the first item's place in the whole list. */
data class MediaDateSection(val title: String, val startIndex: Int, val items: List<BlossomMediaItem>)

/**
 * The gallery's date headings: Today / This Week / This Month / month, with
 * the year added for older years. Port of iOS `MediaDateGrouping`.
 *
 * "This Week" is the calendar week containing [now], not the last seven days.
 */
object MediaDateGrouping {
    const val UNDATED = "Undated"

    fun bucketKey(
        epochSeconds: Long,
        now: LocalDate,
        zone: ZoneId = ZoneId.systemDefault(),
        locale: Locale = Locale.getDefault(),
    ): String {
        // No upload time and no file time: there is nothing to date it by.
        if (epochSeconds <= 0) return UNDATED
        val date = Instant.ofEpochSecond(epochSeconds).atZone(zone).toLocalDate()
        if (date == now) return "Today"
        val week = WeekFields.of(locale)
        if (date.get(week.weekBasedYear()) == now.get(week.weekBasedYear()) &&
            date.get(week.weekOfWeekBasedYear()) == now.get(week.weekOfWeekBasedYear())
        ) {
            return "This Week"
        }
        if (date.year == now.year && date.month == now.month) return "This Month"
        val month = date.month.getDisplayName(TextStyle.FULL_STANDALONE, locale)
        // Within the current year the year is noise; older media needs it.
        return if (date.year == now.year) month else "$month ${date.year}"
    }

    /**
     * Splits [items] into consecutive runs sharing a heading, in the order
     * given — never reorders. Under a sort that is not by date the whole list
     * is one untitled section, so no heading sits above unrelated months.
     */
    fun sections(
        items: List<BlossomMediaItem>,
        sort: MediaSortOption,
        now: LocalDate = LocalDate.now(),
        zone: ZoneId = ZoneId.systemDefault(),
        locale: Locale = Locale.getDefault(),
    ): List<MediaDateSection> {
        if (items.isEmpty()) return emptyList()
        if (!sort.groupsByDate) return listOf(MediaDateSection("", 0, items))
        val runs = mutableListOf<MediaDateSection>()
        var title: String? = null
        var start = 0
        items.forEachIndexed { i, item ->
            val key = bucketKey(item.sortTime, now, zone, locale)
            if (key != title) {
                if (title != null) runs.add(MediaDateSection(title!!, start, items.subList(start, i)))
                title = key
                start = i
            }
        }
        runs.add(MediaDateSection(title!!, start, items.subList(start, items.size)))
        return runs
    }
}
