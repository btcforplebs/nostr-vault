package com.nostrvault.service.shareportal

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.ZoneOffset

/**
 * A shared `.ics` file or a page's JSON-LD Event → the fields of a NIP-52
 * calendar event (contract §6.3). Pure. Twin: CalendarShareParser.swift.
 */
object CalendarShareParser {
    /**
     * [startDate]/[endDate] (`YYYY-MM-DD`) when [allDay], else
     * [startTs]/[endTs] (unix seconds). [tzid] only for an ICS `TZID` time.
     */
    data class Event(
        val title: String = "",
        val description: String = "",
        val location: String = "",
        val url: String = "",
        val allDay: Boolean = false,
        val startDate: String? = null,
        val endDate: String? = null,
        val startTs: Long? = null,
        val endTs: Long? = null,
        val tzid: String? = null,
    ) {
        val hasStart: Boolean get() = if (allDay) startDate != null else startTs != null
    }

    private sealed interface Time {
        data class Day(val date: String) : Time
        data class Instant(val ts: Long, val tzid: String?) : Time
    }

    // ── ICS ──────────────────────────────────────────────────────────

    fun ics(text: String, defaultZone: ZoneId): Event {
        val lines = text.replace(Regex("\\r?\\n[ \\t]"), "").replace("\r\n", "\n").split("\n")
        var inEvent = false
        val props = mutableMapOf<String, Pair<Map<String, String>, String>>()
        for (l in lines) {
            val upper = l.trim().uppercase()
            if (upper == "BEGIN:VEVENT") { inEvent = true; continue }
            if (upper == "END:VEVENT" && inEvent) break
            if (!inEvent || ':' !in l) continue
            val head = l.substringBefore(':')
            val value = l.substringAfter(':')
            val parts = head.split(";")
            val name = parts[0].uppercase()
            val params = parts.drop(1).filter { '=' in it }.associate {
                it.substringBefore('=').uppercase() to it.substringAfter('=').trim('"')
            }
            if (name !in props) props[name] = params to value
        }
        fun txt(k: String) = props[k]?.let { unescape(it.second).trim() }.orEmpty()
        var ev = Event(
            title = txt("SUMMARY"), description = txt("DESCRIPTION"), location = txt("LOCATION"),
            url = props["URL"]?.second?.trim().orEmpty(),
        )
        val start = props["DTSTART"]?.let { icsTime(it.first, it.second.trim(), defaultZone) } ?: return ev
        val end = props["DTEND"]?.let { icsTime(it.first, it.second.trim(), defaultZone) }
        ev = withTimes(ev, start, end)
        return ev
    }

    private fun unescape(v: String): String {
        val out = StringBuilder()
        var i = 0
        while (i < v.length) {
            val c = v[i]
            if (c == '\\' && i + 1 < v.length) {
                when (val n = v[i + 1]) {
                    'n', 'N' -> out.append('\n')
                    ',', ';', '\\' -> out.append(n)
                    else -> out.append('\\').append(n)
                }
                i += 2
            } else {
                out.append(c); i++
            }
        }
        return out.toString()
    }

    private val icsDateTime = Regex("(\\d{4})(\\d{2})(\\d{2})T(\\d{2})(\\d{2})(\\d{2})(Z?)")

    private fun icsTime(params: Map<String, String>, value: String, defaultZone: ZoneId): Time? {
        if (params["VALUE"] == "DATE" || Regex("\\d{8}").matches(value)) {
            if (value.length < 8) return null
            return Time.Day("${value.substring(0, 4)}-${value.substring(4, 6)}-${value.substring(6, 8)}")
        }
        val m = icsDateTime.matchEntire(value) ?: return null
        val g = m.groupValues
        val local = runCatching {
            LocalDateTime.of(g[1].toInt(), g[2].toInt(), g[3].toInt(), g[4].toInt(), g[5].toInt(), g[6].toInt())
        }.getOrNull() ?: return null
        val tzid = params["TZID"]
        val (zone, kept) = when {
            g[7] == "Z" -> ZoneOffset.UTC to null
            tzid != null -> (runCatching { ZoneId.of(tzid) }.getOrNull() ?: return null) to tzid
            else -> defaultZone to null
        }
        return Time.Instant(local.atZone(zone).toEpochSecond(), kept)
    }

    // ── JSON-LD Event ────────────────────────────────────────────────

    fun ldEvent(html: String): Event {
        val e = ShareLd.find(html, "Event") ?: return Event()
        fun g(k: String) = ShareLd.string(e[k])?.let(ShareLd::clean).orEmpty()
        var ev = Event(title = g("name"), description = g("description"), url = ShareLd.string(e["url"])?.trim().orEmpty())
        var loc = e["location"]
        if (loc is JsonArray) loc = loc.firstOrNull()
        val locString = ShareLd.string(loc)
        ev = ev.copy(location = when {
            locString != null -> ShareLd.clean(locString)
            loc is JsonObject -> {
                val bits = mutableListOf<String>()
                ShareLd.string(loc["name"])?.let(ShareLd::clean)?.takeIf { it.isNotEmpty() }?.let(bits::add)
                val a = loc["address"]
                val aString = ShareLd.string(a)
                if (aString != null) {
                    ShareLd.clean(aString).takeIf { it.isNotEmpty() }?.let(bits::add)
                } else if (a is JsonObject) {
                    val ab = listOf("streetAddress", "addressLocality", "addressRegion", "postalCode", "addressCountry")
                        .mapNotNull { k -> ShareLd.string(a[k])?.let(ShareLd::clean)?.takeIf { it.isNotEmpty() } }
                    if (ab.isNotEmpty()) bits += ab.joinToString(", ")
                }
                bits.joinToString(", ")
            }
            else -> ""
        })
        val start = ShareLd.string(e["startDate"])?.let(::isoTime) ?: return ev
        val end = ShareLd.string(e["endDate"])?.let(::isoTime)
        return withTimes(ev, start, end)
    }

    private fun isoTime(s: String): Time? {
        val t = s.trim()
        if (Regex("\\d{4}-\\d{2}-\\d{2}").matches(t)) return Time.Day(t)
        return runCatching { Time.Instant(OffsetDateTime.parse(t).toEpochSecond(), null) }.getOrNull()
    }

    private fun withTimes(ev: Event, start: Time, end: Time?): Event = when (start) {
        is Time.Day -> {
            val e = (end as? Time.Day)?.date
                ?: runCatching { LocalDate.parse(start.date).plusDays(1).toString() }.getOrNull()
            ev.copy(allDay = true, startDate = start.date, endDate = e)
        }
        is Time.Instant -> ev.copy(allDay = false, startTs = start.ts, endTs = (end as? Time.Instant)?.ts, tzid = start.tzid)
    }
}
