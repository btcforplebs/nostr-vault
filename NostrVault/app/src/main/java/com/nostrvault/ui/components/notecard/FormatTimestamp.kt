package com.nostrvault.ui.components

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import com.nostrvault.ui.theme.*

// ── Formatting helpers ────────────────────────────────────────────

internal fun formatTimestamp(epochSecs: Long): String =
    formatTimestamp(epochSecs, System.currentTimeMillis() / 1000)

/**
 * Relative time for a week, then a date: "Sep 24" for this year,
 * "Sep 24, 2025" for any other year (iOS `relativeTime`, PR #69).
 */
internal fun formatTimestamp(
    epochSecs: Long,
    nowSecs: Long,
    zone: java.time.ZoneId = java.time.ZoneId.systemDefault(),
    locale: java.util.Locale = java.util.Locale.getDefault(),
): String {
    val diff = nowSecs - epochSecs
    return when {
        diff < 60 -> "now"
        diff < 3600 -> "${diff / 60}m"
        diff < 86400 -> "${diff / 3600}h"
        diff < 604800 -> "${diff / 86400}d"
        else -> {
            val date = java.time.Instant.ofEpochSecond(epochSecs).atZone(zone)
            val sameYear = date.year == java.time.Instant.ofEpochSecond(nowSecs).atZone(zone).year
            val pattern = if (sameYear) "MMM d" else "MMM d, yyyy"
            java.time.format.DateTimeFormatter.ofPattern(pattern, locale).format(date)
        }
    }
}
