package com.nostrvault.shareportal

import com.nostrvault.service.LabelPublisher
import com.nostrvault.service.UserStatusPublisher
import com.nostrvault.service.shareportal.ArticleClipDraft
import com.nostrvault.service.shareportal.CalendarShareParser
import com.nostrvault.service.shareportal.CalendarShareTags
import com.nostrvault.service.shareportal.RecipeLdParser
import com.nostrvault.shareportal.ShareFixtures.str
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.longOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneId

/** Share portal lane A (contract §6) against the same fixtures the Swift tests read. */
class LaneAFixtureTest {
    private val cases = ShareFixtures.load("lane-a-cases.json")
    private fun list(key: String) = cases.getValue(key).jsonArray.map { it.jsonObject }
    private fun tags(e: kotlinx.serialization.json.JsonElement) =
        e.jsonArray.map { t -> t.jsonArray.map { (it as JsonPrimitive).content } }

    @Test fun clip() {
        val all = list("clip")
        assertTrue(all.size >= 5)
        for (c in all) {
            val i = c.getValue("input").jsonObject
            val e = c.getValue("expect").jsonObject
            val got = ArticleClipDraft.clip(i.str("title"), i.str("url"), i.str("selection"))
            assertEquals(c.str("name"), e.str("title"), got.title)
            assertEquals(c.str("name"), e.str("body"), got.body)
        }
    }

    @Test fun duration() {
        for (c in list("duration")) assertEquals(c.str("in"), c.str("out"), RecipeLdParser.duration(c.str("in")!!))
    }

    @Test fun recipe() {
        val all = list("recipe")
        assertTrue(all.size >= 3)
        for (c in all) {
            val e = c.getValue("expect").jsonObject
            val r = RecipeLdParser.parse(c.str("html")!!, c.str("page_title"), c.str("url"))
            val name = c.str("name")
            assertEquals(name, e.str("title"), r.title)
            assertEquals(name, e.str("summary"), r.summary)
            assertEquals(name, e.str("prepTime"), r.prepTime)
            assertEquals(name, e.str("cookTime"), r.cookTime)
            assertEquals(name, e.str("servings"), r.servings)
            assertEquals(name, e.str("ingredients"), r.ingredients)
            assertEquals(name, e.str("directions"), r.directions)
            assertEquals(name, e.str("categories"), r.categories)
            assertEquals(name, e.str("body"), r.body)
        }
    }

    private fun assertEvent(name: String?, e: JsonObject, got: CalendarShareParser.Event) {
        assertEquals(name, e.str("title"), got.title)
        assertEquals(name, e.str("description"), got.description)
        assertEquals(name, e.str("location"), got.location)
        assertEquals(name, e.str("url"), got.url)
        val allDay = (e["all_day"] as JsonPrimitive).booleanOrNull!!
        assertEquals(name, allDay, got.allDay)
        val start = e["start"]; val end = e["end"]
        if (allDay) {
            assertEquals(name, (start as JsonPrimitive).content, got.startDate)
            assertEquals(name, (end as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content, got.endDate)
        } else {
            assertEquals(name, (start as? JsonPrimitive)?.longOrNull, got.startTs)
            assertEquals(name, (end as? JsonPrimitive)?.longOrNull, got.endTs)
        }
        assertEquals(name, e.str("tzid"), got.tzid)
    }

    @Test fun ics() {
        val all = list("ics")
        assertTrue(all.size >= 5)
        for (c in all) {
            val got = CalendarShareParser.ics(c.str("ics")!!, ZoneId.of(c.str("default_tz")!!))
            assertEvent(c.str("name"), c.getValue("expect").jsonObject, got)
        }
    }

    @Test fun eventLd() {
        for (c in list("event_ld")) assertEvent(c.str("name"), c.getValue("expect").jsonObject, CalendarShareParser.ldEvent(c.str("html")!!))
    }

    @Test fun calendarTags() {
        for (c in list("calendar_tags")) {
            val e = c.getValue("event").jsonObject
            val allDay = (e["all_day"] as JsonPrimitive).booleanOrNull!!
            val ev = CalendarShareParser.Event(
                title = e.str("title").orEmpty(), description = e.str("description").orEmpty(),
                location = e.str("location").orEmpty(), url = e.str("url").orEmpty(), allDay = allDay,
                startDate = if (allDay) e.str("start") else null, endDate = if (allDay) e.str("end") else null,
                startTs = if (allDay) null else (e["start"] as? JsonPrimitive)?.longOrNull,
                endTs = if (allDay) null else (e["end"] as? JsonPrimitive)?.longOrNull,
                tzid = e.str("tzid"),
            )
            val x = c.getValue("expect").jsonObject
            val got = CalendarShareTags.build(ev, c.str("d")!!)
            assertEquals(c.str("name"), (x["kind"] as JsonPrimitive).intOrNull, got.kind)
            assertEquals(c.str("name"), tags(x.getValue("tags")), got.tags)
            assertEquals(c.str("name"), x.str("content"), got.content)
        }
    }

    @Test fun statusTags() {
        for (c in list("status_tags")) {
            val x = c.getValue("expect").jsonObject
            assertEquals((x["kind"] as JsonPrimitive).intOrNull, UserStatusPublisher.KIND)
            val exp = (c["expiration"] as JsonPrimitive).longOrNull!!
            assertEquals(tags(x.getValue("tags")), UserStatusPublisher.tags(c.str("text")!!, c.str("url"), exp))
            assertEquals(x.str("content"), c.str("text")!!.trim())
        }
    }

    @Test fun labelTags() {
        assertEquals(cases.getValue("labels").jsonArray.map { (it as JsonPrimitive).content }, LabelPublisher.LABELS)
        assertEquals(cases.str("label_namespace"), LabelPublisher.NAMESPACE)
        for (c in list("label_tags")) {
            val x = c.getValue("expect").jsonObject
            assertEquals((x["kind"] as JsonPrimitive).intOrNull, LabelPublisher.KIND)
            assertEquals(tags(x.getValue("tags")), LabelPublisher.tags(c.str("label")!!, c.str("url")!!))
            assertEquals(x.str("content"), c.str("comment")!!.trim())
        }
    }

    @Test fun laneAActionsAreOffered() {
        val laneA = listOf(ShareAction.ARTICLE_CLIP, ShareAction.RECIPE, ShareAction.CALENDAR, ShareAction.STATUS, ShareAction.LABEL)
        assertEquals(laneA, ShareActionAvailability.available(laneA))
    }

    @Test fun statusExpiryChoicesDefaultToAnHour() {
        assertEquals(listOf(1800L, 3600L, 14400L), UserStatusPublisher.EXPIRY_CHOICES)
        assertEquals(3600L, UserStatusPublisher.DEFAULT_EXPIRY)
    }
}

class CalendarEditFieldsTest {
    private val ny = java.time.ZoneId.of("America/New_York")
    private val timed = com.nostrvault.service.shareportal.CalendarShareParser.Event(
        title = "T", startTs = 1793898000, endTs = 1793903400, tzid = "America/New_York",
    )

    @Test fun timedRoundTripsInTheEventsZone() {
        val f = com.nostrvault.service.shareportal.CalendarEditFields
        val utc = java.time.ZoneOffset.UTC
        assertEquals("2026-11-05 12:00", f.startText(timed, utc))
        assertEquals(timed, f.apply(timed, false, f.startText(timed, utc), f.endText(timed, utc), utc))
    }

    @Test fun allDayBlankEndIsTheNextDayAndEndBeforeStartIsRefused() {
        val f = com.nostrvault.service.shareportal.CalendarEditFields
        val ev = com.nostrvault.service.shareportal.CalendarShareParser.Event(title = "D")
        assertEquals("2026-12-25", f.apply(ev, true, "2026-12-24", "", ny)!!.endDate)
        org.junit.Assert.assertNull(f.apply(ev, true, "2026-12-24", "2026-12-20", ny))
        org.junit.Assert.assertNull(f.apply(ev, false, "tomorrow", "", ny))
    }

    /** What the date and time pickers write is what apply() reads back. */
    @Test fun pickerTextRoundTrips() {
        val f = com.nostrvault.service.shareportal.CalendarEditFields
        val day = java.time.LocalDate.of(2026, 11, 5)
        assertEquals("2026-11-05", f.fieldText(day, null, allDay = true))
        assertEquals("2026-11-05 09:00", f.fieldText(day, null, allDay = false))
        val timed = f.fieldText(day, java.time.LocalTime.of(12, 0), allDay = false)
        assertEquals("2026-11-05 12:00", timed)
        assertEquals(day, f.datePart(timed))
        assertEquals(java.time.LocalTime.of(12, 0), f.timePart(timed))
        org.junit.Assert.assertNull(f.timePart("2026-11-05"))
        assertEquals(1793898000L, f.apply(this.timed, false, timed, "", ny)!!.startTs)
    }
}
