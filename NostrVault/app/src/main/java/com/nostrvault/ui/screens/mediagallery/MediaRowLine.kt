package com.nostrvault.ui.screens

import com.nostrvault.ui.screens.dashboard.formatSize
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/** The Media list row's detail line (D1; iOS `MediaSizeOrder.rowLine`): "2.4 MB · Video · 3 Nov". */
object MediaRowLine {
    fun typeLabel(item: BlossomMediaItem): String = when {
        item.isGif -> "GIF"
        item.isImage -> "Photo"
        item.isVideo -> "Video"
        item.isAudio -> "Audio"
        else -> "File"
    }

    /** "—" for an unknown size, the date left out when undated, the year only for another year. */
    fun text(
        size: Long?,
        type: String,
        epochSeconds: Long,
        now: LocalDate = LocalDate.now(),
        zone: ZoneId = ZoneId.systemDefault(),
        locale: Locale = Locale.getDefault(),
    ): String {
        val parts = mutableListOf(if (size != null && size > 0) formatSize(size) else "—", type)
        if (epochSeconds > 0) {
            val date = Instant.ofEpochSecond(epochSeconds).atZone(zone).toLocalDate()
            val pattern = if (date.year == now.year) "d MMM" else "d MMM yyyy"
            parts.add(date.format(DateTimeFormatter.ofPattern(pattern, locale)))
        }
        return parts.joinToString(" · ")
    }

    fun host(url: String): String? = runCatching { java.net.URI(url).host }.getOrNull()?.takeIf { it.isNotBlank() }
}
