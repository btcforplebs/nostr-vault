package com.nostrvault.fips

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneId

/** The port of iOS KioskDailyBudget / KioskCapPause that replaces "Pause after" (iPhone #1023). */
class KioskDailyBudgetTest {
    private val zone = ZoneId.of("America/New_York")
    private fun at(day: Int, hour: Int) = LocalDateTime.of(2026, 11, day, hour, 0).atZone(zone).toInstant().toEpochMilli()
    private val mb = 1L shl 20

    @Test fun `counts strangers across polls and sessions, and a new day starts from nothing`() {
        var b = KioskDailyBudget().roll(at(8, 9), zone).engineStarted()
        assertEquals("2026-11-08", b.day)
        b = b.record(100 * mb, at(8, 9), zone).record(300 * mb, at(8, 10), zone)
        assertEquals(300 * mb, b.usedBytes)
        // A restarted engine counts from zero: all of its count is new.
        b = b.engineStarted().record(50 * mb, at(8, 11), zone)
        assertEquals(350 * mb, b.usedBytes)
        assertEquals(KioskDailyBudget.DAILY - 350 * mb, b.sessionLimit)
        // Lower than the last poll: the engine started counting again.
        b = b.record(10 * mb, at(8, 12), zone)
        assertEquals(360 * mb, b.usedBytes)
        b = b.record(20 * mb, at(9, 1), zone)
        assertEquals("2026-11-09", b.day)
        assertEquals(10 * mb, b.usedBytes)
    }

    @Test fun `never more than the day, and a spent day still sends 1 byte, not the engine default`() {
        val b = KioskDailyBudget(day = "2026-11-08").record(5L shl 30, at(8, 9), zone)
        assertEquals(KioskDailyBudget.DAILY, b.usedBytes)
        assertTrue(b.spent)
        assertEquals(1L, b.sessionLimit)
    }

    @Test fun `the cap waits until tomorrow for a session started today, and not for yesterday's`() {
        val (today, until) = KioskDailyBudget(day = "2026-11-08", usedBytes = 900 * mb).capReached("2026-11-08", at(8, 15), zone)
        assertTrue(today.spent)
        assertEquals(at(9, 0), until)
        val (_, now) = KioskDailyBudget(day = "2026-11-07").capReached("2026-11-07", at(8, 0) + 60_000, zone)
        assertEquals(at(8, 0) + 60_000, now)
    }

    @Test fun `the poll pauses once, then resumes when the time comes`() {
        assertEquals(KioskDailyBudget.Step.NONE, KioskDailyBudget.step(capReached = false, pausedUntilMs = null, nowMs = 0))
        assertEquals(KioskDailyBudget.Step.PAUSE, KioskDailyBudget.step(capReached = true, pausedUntilMs = null, nowMs = 0))
        assertEquals(KioskDailyBudget.Step.NONE, KioskDailyBudget.step(capReached = true, pausedUntilMs = 10, nowMs = 5))
        assertEquals(KioskDailyBudget.Step.RESUME, KioskDailyBudget.step(capReached = true, pausedUntilMs = 10, nowMs = 10))
    }

    @Test fun `the budget is written in steps, a new day, or once spent`() {
        val saved = KioskDailyBudget(day = "2026-11-08", usedBytes = 100 * mb)
        assertFalse(budgetNeedsWrite(saved, saved.copy(usedBytes = 100 * mb + BUDGET_PERSIST_STEP - 1)))
        assertTrue(budgetNeedsWrite(saved, saved.copy(usedBytes = 100 * mb + BUDGET_PERSIST_STEP)))
        assertTrue(budgetNeedsWrite(saved, saved.copy(day = "2026-11-09", usedBytes = 0)))
        assertTrue(budgetNeedsWrite(saved.copy(usedBytes = KioskDailyBudget.DAILY - 1), saved.copy(usedBytes = KioskDailyBudget.DAILY)))
    }
}
