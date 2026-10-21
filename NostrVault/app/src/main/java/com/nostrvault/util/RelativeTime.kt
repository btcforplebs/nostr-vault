package com.nostrvault.util

import java.time.Instant
import java.time.ZoneId
import java.time.temporal.ChronoUnit
import kotlin.math.abs
import kotlin.math.roundToLong

/**
 * Relative times worded the way iOS words them, so a row reads the same on
 * both apps. Measured against Foundation on macOS 27 (en_US).
 */
object RelativeTime {

    /**
     * iOS `RelativeDateTimeFormatter`, `.abbreviated`: "30s ago", "5m ago",
     * "2h ago", "3d ago", "1w ago", "1mo ago", "2y ago". Calendar units,
     * truncated, so 89 s is "1m ago" and 23 h 59 m is "23h ago". A time in
     * the future (clock skew) reads "in 1m"; iOS shows "in 0s" for now.
     */
    fun abbreviated(epochSec: Long, nowSec: Long, zone: ZoneId = ZoneId.systemDefault()): String {
        val future = epochSec >= nowSec
        val a = Instant.ofEpochSecond(minOf(epochSec, nowSec)).atZone(zone)
        val b = Instant.ofEpochSecond(maxOf(epochSec, nowSec)).atZone(zone)
        val years = ChronoUnit.YEARS.between(a, b)
        val months = ChronoUnit.MONTHS.between(a, b)
        val days = ChronoUnit.DAYS.between(a, b)
        val hours = ChronoUnit.HOURS.between(a, b)
        val minutes = ChronoUnit.MINUTES.between(a, b)
        val amount = when {
            years > 0 -> "${years}y"
            months > 0 -> "${months}mo"
            days >= 7 -> "${days / 7}w"
            days > 0 -> "${days}d"
            hours > 0 -> "${hours}h"
            minutes > 0 -> "${minutes}m"
            else -> "${ChronoUnit.SECONDS.between(a, b)}s"
        }
        return if (future) "in $amount" else "$amount ago"
    }

    /**
     * iOS `Date.formatted(.relative(presentation: .numeric))`: "2 minutes ago",
     * "1 hour ago", "4 weeks ago", "2 months ago". Seconds to weeks round to
     * the nearest unit and carry up (90 s is "2 minutes ago", 59 m 59 s is
     * "1 hour ago"); from 27 days on it counts calendar months, rounding up
     * once 20 days into the next one, then whole years. Fitted to Foundation's
     * output; a time right on a unit boundary can differ by one.
     */
    fun numeric(epochSec: Long, nowSec: Long, zone: ZoneId = ZoneId.systemDefault()): String {
        val diff = nowSec - epochSec
        val s = abs(diff).toDouble()
        val days = s / 86_400
        val (n, unit) = when {
            s.roundToLong() < 60 -> s.roundToLong() to "second"
            (s / 60).roundToLong() < 60 -> (s / 60).roundToLong() to "minute"
            (s / 3_600).roundToLong() < 24 -> (s / 3_600).roundToLong() to "hour"
            days.roundToLong() < 7 -> days.roundToLong() to "day"
            days < 27 -> (days / 7).roundToLong() to "week"
            else -> {
                val a = Instant.ofEpochSecond(minOf(epochSec, nowSec)).atZone(zone)
                val b = Instant.ofEpochSecond(maxOf(epochSec, nowSec)).atZone(zone)
                var months = ChronoUnit.MONTHS.between(a, b)
                if (ChronoUnit.DAYS.between(a.plusMonths(months), b) >= 20) months++
                if (months < 12) months.coerceAtLeast(1) to "month"
                else maxOf(1, ChronoUnit.YEARS.between(a, b)) to "year"
            }
        }
        val words = "$n $unit" + if (n == 1L) "" else "s"
        return if (diff <= 0) "in $words" else "$words ago"
    }
}
