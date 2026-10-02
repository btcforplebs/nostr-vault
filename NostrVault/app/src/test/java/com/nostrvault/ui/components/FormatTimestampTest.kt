package com.nostrvault.ui.components

import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneOffset
import java.util.Locale

/** Note timestamps: relative for a week, then a date with the year only when it differs. */
class FormatTimestampTest {
    private val utc = ZoneOffset.UTC
    private fun secs(y: Int, mo: Int, d: Int, h: Int = 12) =
        LocalDateTime.of(y, mo, d, h, 0).toEpochSecond(utc)
    private fun fmt(then: Long, now: Long) = formatTimestamp(then, now, utc, Locale.US)

    private val now = secs(2026, 10, 2)

    @Test fun `relative within a week`() {
        assertEquals("now", fmt(now - 59, now))
        assertEquals("now", fmt(now + 30, now))
        assertEquals("1m", fmt(now - 60, now))
        assertEquals("59m", fmt(now - 3599, now))
        assertEquals("1h", fmt(now - 3600, now))
        assertEquals("23h", fmt(now - 86399, now))
        assertEquals("1d", fmt(now - 86400, now))
        assertEquals("6d", fmt(now - 604799, now))
    }

    @Test fun `this year shows month and day`() {
        assertEquals("Sep 24", fmt(secs(2026, 9, 24), now))
        assertEquals("Jan 1", fmt(secs(2026, 1, 1, 0), now))
    }

    @Test fun `another year adds the year`() {
        assertEquals("Sep 24, 2025", fmt(secs(2025, 9, 24), now))
        assertEquals("Dec 31, 2025", fmt(secs(2025, 12, 31, 23), now))
        assertEquals("Mar 5, 2019", fmt(secs(2019, 3, 5), now))
    }

    @Test fun `year boundary within a week stays relative`() {
        val newYear = secs(2026, 1, 2)
        assertEquals("2d", fmt(secs(2025, 12, 31), newYear))
    }

    @Test fun `year is judged in the local zone`() {
        // 2025-12-31 23:00 UTC is already 2026 in UTC+2.
        val then = secs(2025, 12, 31, 23)
        assertEquals("Jan 1", formatTimestamp(then, now, ZoneOffset.ofHours(2), Locale.US))
    }
}
