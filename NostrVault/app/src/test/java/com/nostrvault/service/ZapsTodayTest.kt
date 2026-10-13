package com.nostrvault.service

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneId

/** "Zaps today" for the Vault glance widget: since local midnight, for you, each receipt once. */
class ZapsTodayTest {

    private val me = "a".repeat(64)
    private val other = "b".repeat(64)
    private val zone = ZoneId.of("America/New_York")

    private fun at(text: String) = LocalDateTime.parse(text).atZone(zone)
    private fun receipt(id: String, createdAt: Long, vararg p: String) =
        ZapsToday.Receipt(id, publisher = "c".repeat(64), recipients = p.toList(), createdAt = createdAt)

    @Test fun theDayStartsAtLocalMidnight() {
        val evening = at("2026-10-13T22:44:00")
        assertEquals(at("2026-10-13T00:00:00").toEpochSecond(), ZapsToday.startOfDay(evening.toInstant().toEpochMilli(), zone))
        // One minute past midnight is the next day.
        val justAfter = at("2026-10-14T00:01:00")
        assertEquals(at("2026-10-14T00:00:00").toEpochSecond(), ZapsToday.startOfDay(justAfter.toInstant().toEpochMilli(), zone))
    }

    @Test fun theDayFollowsTheClockAcrossADaylightSavingChange() {
        // Clocks go back on 2026-11-01 in New York: that day is 25 hours long.
        val lateThatDay = at("2026-11-01T23:30:00")
        assertEquals(at("2026-11-01T00:00:00").toEpochSecond(), ZapsToday.startOfDay(lateThatDay.toInstant().toEpochMilli(), zone))
    }

    @Test fun countsOnlyTodaysReceiptsToYouEachOnce() {
        val midnight = at("2026-10-13T00:00:00").toEpochSecond()
        val receipts = listOf(
            receipt("1", midnight, me),            // at midnight: today
            receipt("2", midnight + 3_600, me.uppercase()),
            receipt("2", midnight + 3_600, me),    // the same receipt from a second relay path
            receipt("3", midnight - 1, me),        // yesterday
            receipt("4", midnight + 60, other),    // someone else's
            receipt("5", midnight + 90, other, me), // names you among others
        )
        assertEquals(3, ZapsToday.count(receipts, me, midnight))
    }

    @Test fun midnightResetsTheCount() {
        val day1 = at("2026-10-13T00:00:00").toEpochSecond()
        val day2 = at("2026-10-14T00:00:00").toEpochSecond()
        val receipts = listOf(receipt("1", day1 + 100, me), receipt("2", day1 + 80_000, me))
        assertEquals(2, ZapsToday.count(receipts, me, day1))
        assertEquals(0, ZapsToday.count(receipts, me, day2))
    }

    @Test fun aReceiptIsReadFromTheEvent() {
        val event = Json.parseToJsonElement(
            """{"id":"r1","pubkey":"pub","kind":9735,"created_at":1760000000,"tags":[["p","$me"],["e","x"],["bolt11","lnbc"]]}""",
        ).jsonObject
        assertEquals(ZapsToday.Receipt("r1", "pub", listOf(me), 1_760_000_000), ZapsToday.Receipt.from(event))
        val notAZap = Json.parseToJsonElement("""{"id":"r2","pubkey":"pub","kind":7,"created_at":1,"tags":[]}""").jsonObject
        assertNull(ZapsToday.Receipt.from(notAZap))
    }
}
