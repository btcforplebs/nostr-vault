package com.nostrvault.ui.screens.dashboard

import com.nostrvault.util.findAllOnce
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull

/**
 * The dashboard's GM tile: how many of your own notes were a "GM", and how
 * many a "Pura Vida", today and all time. Read from your own vault only; no
 * network and nothing published.
 *
 * A note counts only when it is basically just the greeting: the greeting
 * plus at most [MAX_EXTRA_WORDS] other words ("gm", "GM!", "Good morning
 * nostr", "gm fam ☕"). Links, nostr: mentions and #tags are ignored, so a
 * "gm" with a photo still counts. A longer note that happens to contain
 * "gm" does not.
 */
internal object GreetingCounts {

    data class Counts(val gmToday: Int, val gmAll: Int, val pvToday: Int, val pvAll: Int)

    enum class Greeting { GM, PURA_VIDA }

    /** Words besides the greeting that a note may still have. */
    const val MAX_EXTRA_WORDS = 2

    private val LINK = Regex("""(?i)\b(?:https?://|nostr:|www\.)\S+""")
    private val TAG = Regex("""(?<!\S)#\S+""")
    private val WORD = Regex("""[\p{L}\p{N}']+""")
    private val GM = Regex("""^(?:gm)+m*$""")

    /** The greetings [content] is, or empty when it is more than a greeting. */
    fun greetings(content: String): Set<Greeting> {
        val text = TAG.replace(LINK.replace(content, " "), " ").lowercase()
        val words = WORD.findAllOnce(text).map { it.value.trim('\'') }.filter { it.isNotEmpty() }.toList()
        if (words.isEmpty()) return emptySet()
        val found = HashSet<Greeting>()
        var greetingWords = 0
        var i = 0
        while (i < words.size) {
            val w = words[i]
            val next = words.getOrNull(i + 1)
            when {
                GM.matches(w) -> { found += Greeting.GM; greetingWords += 1; i += 1 }
                w == "good" && (next == "morning" || next == "mornin") -> { found += Greeting.GM; greetingWords += 2; i += 2 }
                w == "pv" -> { found += Greeting.PURA_VIDA; greetingWords += 1; i += 1 }
                w == "pura" && next == "vida" -> { found += Greeting.PURA_VIDA; greetingWords += 2; i += 2 }
                else -> i += 1
            }
        }
        return if (found.isNotEmpty() && words.size - greetingWords <= MAX_EXTRA_WORDS) found else emptySet()
    }

    /**
     * The counts over [notes] (kind-1 events) by [author], with "today"
     * meaning created at or after [todayStartSec]. Each id counts once.
     */
    fun count(notes: List<JsonObject>, author: String, todayStartSec: Long): Counts {
        var gmToday = 0; var gmAll = 0; var pvToday = 0; var pvAll = 0
        val seen = HashSet<String>()
        for (note in notes) {
            if (note.str("pubkey")?.lowercase() != author.lowercase()) continue
            if ((note["kind"] as? JsonPrimitive)?.longOrNull != 1L) continue
            val id = note.str("id") ?: continue
            if (!seen.add(id)) continue
            val found = greetings(note.str("content") ?: continue)
            if (found.isEmpty()) continue
            val today = ((note["created_at"] as? JsonPrimitive)?.longOrNull ?: 0L) >= todayStartSec
            if (Greeting.GM in found) { gmAll++; if (today) gmToday++ }
            if (Greeting.PURA_VIDA in found) { pvAll++; if (today) pvToday++ }
        }
        return Counts(gmToday, gmAll, pvToday, pvAll)
    }

    /** The store read's filter for one page of [author]'s notes, newest first, at or before [until]. */
    fun pageFilter(author: String, until: Long?, limit: Int): String =
        buildString {
            append("{\"kinds\":[1],\"authors\":[\"").append(author.lowercase()).append("\"],\"limit\":").append(limit)
            if (until != null) append(",\"until\":").append(until)
            append('}')
        }

    /**
     * Every note of [author]'s that [read] (one store page per call) gives,
     * walking back with `until` until a page comes back short. Null when the
     * store can't answer. `until` is inclusive, so a second shared at a page
     * edge is read again and its notes dropped as already seen; a page of
     * nothing new steps one second past the edge.
     */
    fun readAll(author: String, pageSize: Int, maxPages: Int, read: (String) -> List<JsonObject>?): List<JsonObject>? {
        val byId = LinkedHashMap<String, JsonObject>()
        var until: Long? = null
        repeat(maxPages) {
            val page = read(pageFilter(author, until, pageSize)) ?: return null
            var added = 0
            var oldest = Long.MAX_VALUE
            for (event in page) {
                val id = event.str("id") ?: continue
                if (byId.putIfAbsent(id, event) == null) added++
                oldest = minOf(oldest, (event["created_at"] as? JsonPrimitive)?.longOrNull ?: 0L)
            }
            if (page.size < pageSize) return byId.values.toList()
            // A full page of notes already seen: they all share the edge
            // second, so step past it.
            until = if (added == 0) oldest - 1 else oldest
        }
        return byId.values.toList()
    }

    /** "GM 12 · PV 3". */
    fun label(gm: Int, pv: Int, format: (Int) -> String): String = "GM ${format(gm)} · PV ${format(pv)}"

    private fun JsonObject.str(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull
}
