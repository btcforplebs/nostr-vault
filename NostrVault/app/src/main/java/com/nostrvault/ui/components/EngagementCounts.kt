package com.nostrvault.ui.components

/**
 * Pure formatting for the engagement counts drawn beside the note-card action
 * icons.
 *
 * These live outside `NoteCard.kt` so a JVM unit test can call them without
 * pulling in Compose. The rules they encode are the ones that decide whether a
 * number is shown at all, so they are worth asserting directly.
 */

/** Compact count: 999 → "999", 1200 → "1.2k", 12_000 → "12k", 2_400_000 → "2.4M". */
internal fun formatCount(count: Long): String {
    return when {
        count < 1000L -> count.toString()
        count < 10_000L -> "%.1fk".format(count / 1000.0)
        count < 1_000_000L -> "${count / 1000L}k"
        count < 10_000_000L -> "%.1fM".format(count / 1_000_000.0)
        count < 1_000_000_000L -> "${count / 1_000_000L}M"
        else -> "%.1fB".format(count / 1_000_000_000.0)
    }
}

internal fun formatCount(count: Int): String = formatCount(count.toLong())

/**
 * Label for a reaction/repost count, or null when there is nothing to say.
 *
 * Zero is *absence of engagement*, not a value worth a glyph — a feed of "0 0 0"
 * reads as broken. Negative can only come from an optimistic decrement racing a
 * backfill, and is treated as zero rather than rendered.
 */
internal fun engagementCountLabel(count: Int): String? =
    if (count > 0) formatCount(count) else null

/**
 * Label for the zap button.
 *
 * A zap's meaning is the amount, not the number of people, so the sats total
 * wins when we have one. A zap receipt whose invoice carried no amount still
 * increments [com.nostrvault.data.model.NoteStats.zapCount], so fall back to the
 * count rather than showing nothing for a note that was demonstrably zapped.
 *
 * Sats are a [Long] and stay one all the way through: a whole-coin zap is past
 * `Int.MAX_VALUE`, and narrowing here would print a negative number on the one
 * note anybody would look twice at.
 */
internal fun zapCountLabel(zapCount: Int, zapAmountSats: Long): String? = when {
    zapAmountSats > 0L -> formatCount(zapAmountSats)
    zapCount > 0 -> formatCount(zapCount)
    else -> null
}
