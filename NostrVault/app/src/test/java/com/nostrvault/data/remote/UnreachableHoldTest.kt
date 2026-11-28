package com.nostrvault.data.remote

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** [RateLimitBackoff.unreachable]: one shared, growing hold per unreachable host. */
class UnreachableHoldTest {
    @After fun clear() {
        RateLimitBackoff.clearForTest()
        AppOnScreen.setForTest(true)
    }

    private val url = "wss://relay.example.com"
    private val t0 = 1_800_000_000_000L

    @Test
    fun `each failed dial doubles the hold from 5 s, up to 2 min on screen`() {
        val holds = (1..8).map { RateLimitBackoff.unreachable(url, down = true, nowMs = t0) }
        assertEquals(listOf(5_000L, 10_000L, 20_000L, 40_000L, 80_000L, 120_000L, 120_000L, 120_000L), holds)
    }

    @Test
    fun `in the background the cap is 10 min, and coming back cuts it to 2 min`() {
        AppOnScreen.setForTest(false)
        repeat(20) { RateLimitBackoff.unreachable(url, down = true, nowMs = t0) }
        assertEquals(10 * 60_000L, RateLimitBackoff.remainingMs(url, t0))
        AppOnScreen.setForTest(true)
        assertEquals(2 * 60_000L, RateLimitBackoff.remainingMs(url, t0))
    }

    @Test
    fun `the hold is shared by every url on the host`() {
        RateLimitBackoff.unreachable("wss://relay.example.com/", down = true, nowMs = t0)
        assertTrue(RateLimitBackoff.remainingMs("wss://RELAY.example.com/inbox", t0) > 0)
    }

    @Test
    fun `an open socket clears it, and an old failure starts the ladder over`() {
        repeat(5) { RateLimitBackoff.unreachable(url, down = true, nowMs = t0) }
        RateLimitBackoff.reached(url)
        assertEquals(0L, RateLimitBackoff.remainingMs(url, t0))
        repeat(5) { RateLimitBackoff.unreachable(url, down = true, nowMs = t0) }
        val later = t0 + RateLimitBackoff.UNREACHABLE_FORGET_MS + 1
        assertEquals(5_000L, RateLimitBackoff.unreachable(url, down = true, nowMs = later))
    }

    @Test
    fun `reached keeps a refusal hold`() {
        RateLimitBackoff.refused(url, nowMs = t0)
        RateLimitBackoff.reached(url)
        assertTrue(RateLimitBackoff.remainingMs(url, t0) > 0)
    }

    @Test
    fun `a timeout holds but does not count as down`() {
        RateLimitBackoff.unreachable(url, down = false, nowMs = t0)
        assertTrue(RateLimitBackoff.remainingMs(url, t0) > 0)
        assertFalse(RateLimitBackoff.heldForFailure(url, t0))
        RateLimitBackoff.unreachable(url, down = true, nowMs = t0)
        assertTrue(RateLimitBackoff.heldForFailure(url, t0))
    }

    @Test
    fun `local and LAN hosts are never held`() {
        for (local in listOf("ws://127.0.0.1:3355/inbox", "ws://localhost:3355", "wss://192.168.4.20:3355")) {
            assertEquals(0L, RateLimitBackoff.unreachable(local, down = true, nowMs = t0))
            assertEquals(0L, RateLimitBackoff.remainingMs(local, t0))
        }
    }
}
