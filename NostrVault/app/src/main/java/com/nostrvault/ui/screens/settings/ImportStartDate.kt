package com.nostrvault.ui.screens.settings

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.time.format.DateTimeParseException

/**
 * The import start date is stored as `yyyy-MM-dd` and read as UTC midnight,
 * the same as the iPhone's date picker (`ImportSettingsView.importDateBinding`).
 * The Material date picker also works in UTC milliseconds, so the two meet here.
 */
internal fun importDateToMillis(date: String): Long? = try {
    LocalDate.parse(date.trim()).atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()
} catch (e: DateTimeParseException) {
    null
}

internal fun importDateFromMillis(millis: Long): String =
    Instant.ofEpochMilli(millis).atZone(ZoneOffset.UTC).toLocalDate().toString()
