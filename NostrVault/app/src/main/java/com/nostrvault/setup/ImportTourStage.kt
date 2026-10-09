package com.nostrvault.setup

import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

/**
 * The import tour's plain-words headline, read from the import's status
 * message (`RelayImportService.importStatusMessage`, set by
 * `RelayLogParser`). The import gives no running count, but the notes part
 * does say which dates it's on, so the headline can say how far back it got.
 * Same as iOS `ImportTourStage`.
 */
data class ImportTourStage(
    /** "Saving your notes from Mar 2024…" */
    val text: String,
    /** 1 connect, 2 notes, 3 replies and mentions, 4 done. */
    val step: Int,
) {
    companion object {
        const val STEP_COUNT = 4

        fun from(statusMessage: String, completed: Boolean): ImportTourStage = when {
            completed -> ImportTourStage("Done. Your notes are home.", 4)
            statusMessage.startsWith("Looking through notes") ->
                month(statusMessage)?.let { ImportTourStage("Looking through $it…", 2) }
                    ?: ImportTourStage("Looking through your history…", 2)
            statusMessage.startsWith("Found notes") ->
                month(statusMessage)?.let { ImportTourStage("Saving your notes from $it…", 2) }
                    ?: ImportTourStage("Saving your notes…", 2)
            statusMessage.startsWith("Importing tagged notes") ->
                ImportTourStage("Saving replies and mentions of you…", 3)
            statusMessage.contains("Web of Trust") -> ImportTourStage("Finding the people you follow…", 1)
            else -> ImportTourStage("Connecting to your relays…", 1)
        }

        /** "Found notes from 2024-03-05T…" → "Mar 2024". */
        fun month(message: String): String? {
            val at = message.indexOf("from ")
            if (at < 0) return null
            val datePart = message.substring(at + 5).take(10)
            if (datePart.length != 10) return null
            val parser = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply {
                timeZone = TimeZone.getTimeZone("UTC")
                isLenient = false
            }
            val date = runCatching { parser.parse(datePart) }.getOrNull() ?: return null
            return SimpleDateFormat("MMM yyyy", Locale.US).apply {
                timeZone = TimeZone.getTimeZone("UTC")
            }.format(date)
        }

        /** "Saving your notes from Mar 2024…" → "notes from Mar 2024", for the
         *  pill shown over the app while an import runs. */
        fun shortText(stage: ImportTourStage): String {
            val s = stage.text
                .replace("Saving your ", "")
                .replace("Saving ", "")
                .replace("Looking through ", "")
                .replace("…", "")
            return s.take(1).lowercase() + s.drop(1)
        }
    }
}
