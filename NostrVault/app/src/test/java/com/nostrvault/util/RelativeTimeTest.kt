package com.nostrvault.util

import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.ZoneOffset

/** Expected strings are Foundation's own output on macOS 27, en_US. */
class RelativeTimeTest {
    private val now = 1_792_000_000L
    private val utc = ZoneOffset.UTC

    @Test fun `abbreviated matches iOS RelativeDateTimeFormatter`() {
        val cases = mapOf(
            1L to "1s ago", 59L to "59s ago", 60L to "1m ago", 89L to "1m ago", 119L to "1m ago",
            120L to "2m ago", 3_599L to "59m ago", 3_600L to "1h ago", 5_400L to "1h ago",
            86_399L to "23h ago", 86_400L to "1d ago", 129_600L to "1d ago", 518_400L to "6d ago",
            604_800L to "1w ago", 1_209_600L to "2w ago", 2_419_200L to "4w ago",
            31_536_000L * 2 to "2y ago", -60L to "in 1m",
        )
        for ((ago, want) in cases) assertEquals("$ago s", want, RelativeTime.abbreviated(now - ago, now, utc))
    }

    @Test fun `abbreviated counts calendar months`() {
        // 2026-10-01 → 2026-12-01 is two calendar months.
        val dec1 = 1_796_083_200L
        val oct1 = 1_790_812_800L
        assertEquals("2mo ago", RelativeTime.abbreviated(oct1, dec1, utc))
    }

    @Test fun `numeric matches iOS relative numeric style`() {
        val day = 86_400L
        val cases = mapOf(
            1L to "1 second ago", 30L to "30 seconds ago", 60L to "1 minute ago", 89L to "1 minute ago",
            90L to "2 minutes ago", 3_599L to "1 hour ago", 5_399L to "1 hour ago", 5_400L to "2 hours ago",
            86_399L to "1 day ago", 129_600L to "2 days ago", 302_400L to "4 days ago", 518_400L to "6 days ago",
            604_800L to "1 week ago", 10 * day to "1 week ago", 21 * day / 2 to "2 weeks ago",
            1_209_600L to "2 weeks ago", 24 * day to "3 weeks ago", 49 * day / 2 to "4 weeks ago",
            26 * day to "4 weeks ago", 27 * day to "1 month ago", 28 * day to "1 month ago",
            30 * day to "1 month ago", 46 * day to "1 month ago", 60 * day to "2 months ago",
            75 * day to "2 months ago", 350 * day to "11 months ago", 31_535_999L to "1 year ago",
            548 * day to "1 year ago", 63_072_000L to "2 years ago", 0L to "in 0 seconds", -60L to "in 1 minute",
        )
        for ((ago, want) in cases) assertEquals("$ago s", want, RelativeTime.numeric(now - ago, now, utc))
    }
}
