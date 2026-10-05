package com.nostrvault.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneOffset
import java.util.Locale

/** Media tab date headings, ported from iOS MediaDateGrouping. */
class MediaDateGroupingTest {
    private val zone = ZoneOffset.UTC
    private val locale = Locale.US // weeks start on Sunday
    // Wednesday 2026-10-14
    private val now = LocalDate.of(2026, 10, 14)

    private fun at(y: Int, m: Int, d: Int) = LocalDate.of(y, m, d).atStartOfDay(zone).toEpochSecond() + 3600

    private fun key(y: Int, m: Int, d: Int) = MediaDateGrouping.bucketKey(at(y, m, d), now, zone, locale)

    @Test fun buckets() {
        assertEquals("Today", key(2026, 10, 14))
        assertEquals("This Week", key(2026, 10, 11)) // Sunday, same calendar week
        assertEquals("This Month", key(2026, 10, 10)) // Saturday of last week
        assertEquals("September", key(2026, 9, 30))
        assertEquals("December 2025", key(2025, 12, 31))
        assertEquals(MediaDateGrouping.UNDATED, MediaDateGrouping.bucketKey(0, now, zone, locale))
    }

    private fun item(id: Char, time: Long) = BlossomMediaItem(
        sha256 = id.toString().repeat(64), displayUrl = "x", localFile = null, mimeType = "image/png",
        size = null, uploaded = time, lastModified = null, isLocal = false,
    )

    @Test fun runsKeepOrderAndStartIndex() {
        val items = listOf(
            item('a', at(2026, 10, 14)),
            item('b', at(2026, 10, 14)),
            item('c', at(2026, 10, 12)),
            item('d', at(2026, 9, 2)),
        )
        val sections = MediaDateGrouping.sections(items, MediaSortOption.NEWEST_FIRST, now, zone, locale)
        assertEquals(listOf("Today", "This Week", "September"), sections.map { it.title })
        assertEquals(listOf(0, 2, 3), sections.map { it.startIndex })
        assertEquals(listOf(2, 1, 1), sections.map { it.items.size })
    }

    @Test fun nonDateSortIsOneUntitledSection() {
        val items = listOf(item('a', at(2026, 10, 14)), item('b', at(2025, 1, 1)))
        val sections = MediaDateGrouping.sections(items, MediaSortOption.MEDIA_TYPE, now, zone, locale)
        assertEquals(1, sections.size)
        assertEquals("", sections[0].title)
        assertEquals(2, sections[0].items.size)
    }
}
