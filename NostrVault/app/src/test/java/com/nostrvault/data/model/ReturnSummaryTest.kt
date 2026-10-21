package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors HavenApp/MediaLogicTests/Tests/MediaLogicTests/ReturnSummaryTests.swift. */
class ReturnSummaryTest {

    // ── The pill's text ──

    @Test fun countsByKindInLogensOrder() {
        val s = ReturnSummary()
        s.add("dm", "d1")
        for (i in 0 until 5) s.add("mention", "m$i")
        s.add("zap", "z1")
        s.add("zap", "z2")
        assertEquals("5 mentions · 2 zaps · 1 DM", s.text)
        assertEquals(8, s.total)
    }

    /** The relay marker and the system alert for one event both reach the pill path; the event counts once. */
    @Test fun oneEventCountsOnce() {
        val s = ReturnSummary()
        assertTrue(s.add("mention", "abc"))
        assertFalse(s.add("mention", "abc"))
        assertEquals("1 mention", s.text)
    }

    @Test fun quoteIsAMentionAndGiftWrapIsADm() {
        val s = ReturnSummary()
        s.add("quote", "q")
        s.add("mention", "m")
        s.add("giftwrap", "g")
        assertEquals(2, s.count(ReturnSummary.Category.MENTION))
        assertEquals(1, s.count(ReturnSummary.Category.DM))
    }

    @Test fun pastThreeKindsTheRestFoldIntoMore() {
        val s = ReturnSummary()
        s.add("mention", "1"); s.add("reply", "2"); s.add("zap", "3")
        s.add("reaction", "4"); s.add("reaction", "5"); s.add("follow", "6")
        assertEquals("1 mention · 1 reply · 1 zap · +3 more", s.text)
        assertEquals("1 mention, 1 reply, 1 zap, 2 reactions, 1 new follower", s.spokenText)
    }

    @Test fun unknownTypeIsAnUpdate() {
        val s = ReturnSummary()
        s.add("something-new", "x")
        assertEquals("1 update", s.text)
    }

    @Test fun empty() {
        assertTrue(ReturnSummary().isEmpty)
        assertEquals("", ReturnSummary().text)
    }

    // ── The gathering window ──

    private val back = 1_800_000_000_000L
    private fun at(seconds: Double) = back + (seconds * 1000).toLong()

    @Test fun nothingArrivesThenItClosesAndLiveTrafficGetsTopPills() {
        val w = ReturnWindow(back)
        assertTrue(w.gathers(at(ReturnWindow.WAIT_FOR_FIRST_MS / 1000.0 - 0.1)))
        assertNull("no arrival, no pill", w.showsUntil)
        assertFalse(w.arrive(at(ReturnWindow.WAIT_FOR_FIRST_MS / 1000.0)))
        assertNull(w.showsUntil)
    }

    @Test fun eachArrivalKeepsItOpenASettleLonger() {
        val w = ReturnWindow(back)
        assertTrue(w.arrive(at(2.0)))
        assertTrue(w.arrive(at(7.0)))
        assertEquals(at(7.0) + ReturnWindow.SETTLE_MS, w.gathersUntil)
        assertTrue(w.gathers(at(12.9)))
        assertFalse(w.gathers(at(13.0)))
    }

    /** A busy account keeps arriving; past the maximum it is live traffic again. */
    @Test fun neverGathersPastTheMaximum() {
        val w = ReturnWindow(back)
        var t = 1.0
        while (w.arrive(at(t))) t += 2
        assertTrue(t <= ReturnWindow.MAXIMUM_MS / 1000.0 + 2)
        assertEquals(back + ReturnWindow.MAXIMUM_MS, w.gathersUntil)
    }

    /** One arrival just before the close still gets a readable pill. */
    @Test fun aLateFirstArrivalStillShowsTheMinimum() {
        val w = ReturnWindow(back)
        assertTrue(w.arrive(at(11.0)))
        assertEquals(at(11.0) + ReturnWindow.SETTLE_MS, w.showsUntil)
        val capped = ReturnWindow(back)
        var t = 1.0
        while (t < ReturnWindow.MAXIMUM_MS / 1000.0 - 1) { capped.arrive(at(t)); t += 4 }
        assertEquals(back + ReturnWindow.MAXIMUM_MS, capped.showsUntil)
        val single = ReturnWindow(back)
        val when_ = back + ReturnWindow.MAXIMUM_MS - 25_000
        single.arrive(when_)
        assertTrue(single.showsUntil!! >= when_ + ReturnWindow.MINIMUM_SHOW_MS)
    }

    // ── Late catch-up ──

    /** A backlog handed over a minute after the return came in while you were away: it joins the pill. */
    @Test fun anOldEventArrivingLateIsStillGathered() {
        val w = ReturnWindow(back)
        assertTrue(w.arrive(at(2.0)))
        assertFalse(w.gathers(at(60.0)))
        assertTrue(w.arrive(at(60.0), createdAt = at(-3600.0)))
        assertEquals("the pill comes back for it", at(60.0) + ReturnWindow.MINIMUM_SHOW_MS, w.showsUntil)
    }

    @Test fun aNewEventAfterTheWindowIsLive() {
        val w = ReturnWindow(back)
        assertFalse(w.arrive(at(60.0), createdAt = at(59.0)))
        assertFalse("a DM has no trustworthy time", w.arrive(at(60.0), createdAt = null))
        assertNull(w.showsUntil)
    }

    @Test fun oldEventsStopBeingGatheredAfterTheHorizon() {
        val w = ReturnWindow(back)
        assertTrue(w.arrive(back + ReturnWindow.LATE_HORIZON_MS - 1000, createdAt = at(-10.0)))
        assertFalse(w.arrive(back + ReturnWindow.LATE_HORIZON_MS, createdAt = at(-10.0)))
    }

    /** A late one does not hold the window open for live traffic. */
    @Test fun aLateArrivalDoesNotReopenTheWindow() {
        val w = ReturnWindow(back)
        assertTrue(w.arrive(at(40.0), createdAt = at(-5.0)))
        assertFalse(w.gathers(at(41.0)))
        assertFalse(w.arrive(at(41.0), createdAt = at(41.0)))
    }
}
