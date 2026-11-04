package com.nostrvault.widget

import com.nostrvault.data.model.LiveStream
import com.nostrvault.data.model.NIP10Thread
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/**
 * The rules behind the Live now and On this day home-screen widgets, free of
 * Android and Glance types so JVM tests reach them. Ports of Your space's
 * panels: iOS `LiveNow.swift` / `OnThisDay.swift` (MediaLogicTests), web
 * `live-now.js` / `on-this-day.js`.
 */
object LiveNowRules {
    /** Rows on a medium widget; a small one draws the first. */
    const val MAX_ROWS = 3

    /** How often an open app asks again: streams start at any time (iOS `LiveNow.refreshEvery`). */
    const val REFRESH_MS = 2 * 60 * 1000L

    /**
     * A widget drawn from a list older than this asks again first, if it can.
     * Half an hour is the launcher's own update period, so each periodic
     * update refetches; a redraw right after the app published does not.
     */
    const val STALE_MS = 10 * 60 * 1000L

    /**
     * The streams of people you follow that are on air at [nowSeconds],
     * newest first, as Your space's Live now: the newest event per stream
     * address wins (an ended stream replaces its own live announcement), the
     * signer or a `p` tag marked Host must be followed, a block on either
     * hides it, and only a stream on air with an HLS URL the player can open
     * counts.
     */
    fun pick(
        streams: List<LiveStream>,
        follows: Set<String>,
        blocked: Set<String>,
        nowSeconds: Long,
    ): List<LiveStream> {
        val newest = mutableMapOf<String, LiveStream>()
        for (s in streams) {
            val have = newest[s.address]
            if (have != null && have.createdAt >= s.createdAt) continue
            newest[s.address] = s
        }
        return newest.values
            .filter { s ->
                s.hosts.none { it in blocked } &&
                    s.hosts.any { it in follows } &&
                    s.isPlayableLive && s.isOnAirAt(nowSeconds)
            }
            .sortedWith(compareByDescending<LiveStream> { it.createdAt }.thenByDescending { it.address })
    }

    /**
     * `nostrvault://live/<address>`, the tap on a stream. The address ends in
     * the stream's free-text `d` tag, so all of it is percent-encoded
     * (spaces as %20, which the router's URLDecoder reads back).
     */
    fun destination(address: String): String =
        "live/" + java.net.URLEncoder.encode(address, "UTF-8").replace("+", "%20")

    /** The calm line drawn when nobody is live (iOS `LiveNow.emptyLine`). */
    fun emptyLine(followsSomeone: Boolean): String =
        if (followsSomeone) "Nobody you follow is live right now." else "Follow people to see when they go live."
}

object OnThisDayRules {
    /** How many years back the widget looks. */
    val YEARS_BACK = listOf(1, 2)

    /** Notes kept per year, the oldest of the day first (iOS `OnThisDay.perYear`). */
    const val PER_YEAR = 3

    /** Rows on a medium widget; a small one draws the first. */
    const val MAX_ROWS = 3

    /** One local day, [years] back: [since] its first second, [until] the next day's (epoch seconds). */
    data class Window(val years: Int, val since: Long, val until: Long)

    /** The fields the widget reads from a note. */
    data class Note(
        val id: String,
        val pubkey: String,
        val kind: Int,
        val createdAt: Long,
        val content: String,
        val tags: List<List<String>>,
    )

    /**
     * Today's date [years] back as a local day, or null when that date did
     * not exist that year (29 February in a year without one).
     */
    fun window(nowMs: Long, years: Int, zone: ZoneId = ZoneId.systemDefault()): Window? {
        val today = Instant.ofEpochMilli(nowMs).atZone(zone).toLocalDate()
        val year = today.year - years
        if (today.monthValue == 2 && today.dayOfMonth == 29 && !java.time.Year.isLeap(year.toLong())) return null
        val day = LocalDate.of(year, today.monthValue, today.dayOfMonth)
        return Window(
            years = years,
            since = day.atStartOfDay(zone).toEpochSecond(),
            until = day.plusDays(1).atStartOfDay(zone).toEpochSecond(),
        )
    }

    fun windows(nowMs: Long, years: List<Int> = YEARS_BACK, zone: ZoneId = ZoneId.systemDefault()): List<Window> =
        years.mapNotNull { window(nowMs, it, zone) }

    /** The vault filter for one window: the owner's own kind 1 notes on that day. */
    fun filter(owner: String, w: Window): String =
        """{"kinds":[1],"authors":["$owner"],"since":${w.since},"until":${w.until - 1},"limit":100}"""

    /**
     * The owner's own top-level kind 1 notes inside [w], oldest first, at most
     * [max], each id once. Replies stay out: what shows is what they posted,
     * not their side of someone else's thread.
     */
    fun notes(notes: List<Note>, owner: String, w: Window, max: Int = PER_YEAR): List<Note> =
        notes.asSequence()
            .filter {
                it.kind == 1 && it.pubkey == owner && it.createdAt >= w.since && it.createdAt < w.until &&
                    NIP10Thread.parentEventId(it.kind, it.tags) == null
            }
            .distinctBy { it.id }
            .sortedBy { it.createdAt }
            .take(max)
            .toList()

    /** "1 year ago", "2 years ago". */
    fun yearsText(n: Int): String = if (n == 1) "1 year ago" else "$n years ago"

    /**
     * One line for a note: its text without picture links (whitespace
     * collapsed), or "Photo" / "Photos" when that is all it has.
     */
    fun lineText(content: String): String {
        val words = content.split(Regex("\\s+")).filter { it.isNotEmpty() }
        val pictures = words.filter(::isPicture)
        val text = words.filterNot(::isPicture).joinToString(" ")
        if (text.isNotEmpty()) return text
        return when {
            pictures.size > 1 -> "Photos"
            pictures.isEmpty() -> "Note"
            else -> "Photo"
        }
    }

    private fun isPicture(word: String): Boolean {
        val lower = word.lowercase()
        if (!lower.startsWith("http://") && !lower.startsWith("https://")) return false
        val path = lower.substringBefore('?')
        return listOf("png", "jpg", "jpeg", "gif", "webp", "avif").any { path.endsWith(".$it") }
    }
}
