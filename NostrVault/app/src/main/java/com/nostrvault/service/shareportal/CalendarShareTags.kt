package com.nostrvault.service.shareportal

/** NIP-52 tags for a shared event (contract §6.3). Pure. Twin: CalendarShareTags.swift. */
object CalendarShareTags {
    const val DATE_KIND = 31922
    const val TIME_KIND = 31923

    data class Built(val kind: Int, val tags: List<List<String>>, val content: String)

    fun build(ev: CalendarShareParser.Event, d: String): Built {
        val tags = mutableListOf(listOf("d", d), listOf("title", ev.title))
        val kind: Int
        if (ev.allDay) {
            kind = DATE_KIND
            ev.startDate?.let { tags += listOf("start", it) }
            ev.endDate?.takeIf { it.isNotEmpty() }?.let { tags += listOf("end", it) }
        } else {
            kind = TIME_KIND
            ev.startTs?.let { tags += listOf("start", it.toString()) }
            ev.endTs?.let { tags += listOf("end", it.toString()) }
            ev.tzid?.takeIf { it.isNotEmpty() }?.let { tags += listOf("start_tzid", it); tags += listOf("end_tzid", it) }
        }
        if (ev.location.isNotEmpty()) tags += listOf("location", ev.location)
        if (ev.url.isNotEmpty()) tags += listOf("r", ev.url)
        tags += listOf("alt", "Calendar event: ${ev.title}")
        return Built(kind, tags, ev.description)
    }
}
