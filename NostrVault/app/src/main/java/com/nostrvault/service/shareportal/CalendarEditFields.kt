package com.nostrvault.service.shareportal

import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * The calendar card's start/end as editable text and back: `YYYY-MM-DD` for
 * an all-day event, `YYYY-MM-DD HH:MM` in the event's zone (its tzid, else
 * this device's) for a timed one. Pure. Twin: CalendarEditFields.swift.
 */
object CalendarEditFields {
    private val timeFormat = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")

    fun zone(ev: CalendarShareParser.Event, device: ZoneId): ZoneId =
        ev.tzid?.let { runCatching { ZoneId.of(it) }.getOrNull() } ?: device

    fun startText(ev: CalendarShareParser.Event, device: ZoneId): String =
        if (ev.allDay) ev.startDate.orEmpty() else ev.startTs?.let { format(it, zone(ev, device)) }.orEmpty()

    fun endText(ev: CalendarShareParser.Event, device: ZoneId): String =
        if (ev.allDay) ev.endDate.orEmpty() else ev.endTs?.let { format(it, zone(ev, device)) }.orEmpty()

    private fun format(ts: Long, zone: ZoneId): String = Instant.ofEpochSecond(ts).atZone(zone).format(timeFormat)

    /**
     * [ev] with the card's edits applied, or null when the start does not
     * parse (Publish stays off). A blank end means no end; for an all-day
     * event that is the next day, as the parser does. An end before the start
     * is refused.
     */
    fun apply(
        ev: CalendarShareParser.Event, allDay: Boolean, start: String, end: String, device: ZoneId,
    ): CalendarShareParser.Event? {
        val s = start.trim(); val e = end.trim()
        if (allDay) {
            val sd = runCatching { LocalDate.parse(s) }.getOrNull() ?: return null
            val ed = if (e.isEmpty()) sd.plusDays(1) else runCatching { LocalDate.parse(e) }.getOrNull() ?: return null
            if (ed.isBefore(sd)) return null
            return ev.copy(allDay = true, startDate = sd.toString(), endDate = ed.toString(), startTs = null, endTs = null, tzid = null)
        }
        val zone = zone(ev, device)
        val st = runCatching { LocalDateTime.parse(s, timeFormat).atZone(zone).toEpochSecond() }.getOrNull() ?: return null
        val et = if (e.isEmpty()) null else runCatching { LocalDateTime.parse(e, timeFormat).atZone(zone).toEpochSecond() }.getOrNull() ?: return null
        if (et != null && et < st) return null
        return ev.copy(allDay = false, startTs = st, endTs = et, startDate = null, endDate = null,
            tzid = ev.tzid.takeIf { !ev.allDay })
    }
}
