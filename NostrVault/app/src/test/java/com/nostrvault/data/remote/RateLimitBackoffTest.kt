package com.nostrvault.data.remote

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** A 429 holds the whole host for hours, not one socket for 2 minutes (damus bans busy IPs). */
class RateLimitBackoffTest {
    @After fun clear() = RateLimitBackoff.clearForTest()

    private val hour = 60 * 60 * 1000L

    @Test
    fun `a 429 holds every socket to the host for an hour`() {
        assertEquals(0L, RateLimitBackoff.remainingMs("wss://relay.damus.io", 0))
        assertEquals(hour, RateLimitBackoff.limited("wss://relay.damus.io/", 0))
        assertEquals(hour, RateLimitBackoff.remainingMs("WSS://Relay.Damus.io", 0))
        assertEquals(hour / 2, RateLimitBackoff.remainingMs("wss://relay.damus.io:443/x", hour / 2))
        assertEquals(0L, RateLimitBackoff.remainingMs("wss://relay.primal.net", 0))
        assertEquals(0L, RateLimitBackoff.remainingMs("wss://relay.damus.io", hour))
    }

    @Test
    fun `each further 429 doubles the hold, up to 12 hours`() {
        val holds = (0 until 7).map { RateLimitBackoff.limited("wss://relay.damus.io", 0) / hour }
        assertEquals(listOf(1L, 2L, 4L, 8L, 12L, 12L, 12L), holds)
    }

    @Test
    fun `a connection that stayed up starts the host over`() {
        RateLimitBackoff.limited("wss://relay.damus.io", 0)
        RateLimitBackoff.limited("wss://relay.damus.io", 0)
        RateLimitBackoff.recovered("wss://relay.damus.io")
        assertEquals(0L, RateLimitBackoff.remainingMs("wss://relay.damus.io", 0))
        assertEquals(hour, RateLimitBackoff.limited("wss://relay.damus.io", 0))
    }

    @Test
    fun `isDamus matches the host only`() {
        assertTrue(isDamus("wss://relay.damus.io"))
        assertTrue(isDamus("WSS://RELAY.DAMUS.IO/"))
        assertFalse(isDamus("wss://damus.io.example.com"))
        assertFalse(isDamus("wss://relay.primal.net"))
    }

    private val min = 60_000L

    @Test
    fun `a refused upgrade holds the host on a 30 s, 2 min, 10 min ladder`() {
        val url = "wss://sendit.nosflare.com"
        assertEquals(30_000L, RateLimitBackoff.refused(url, 0))
        assertEquals(30_000L, RateLimitBackoff.remainingMs("wss://SENDIT.nosflare.com/x", 0))
        assertEquals(2 * min, RateLimitBackoff.refused(url, 30_000L))
        assertEquals(10 * min, RateLimitBackoff.refused(url, 30_000L + 2 * min))
        assertEquals(10 * min, RateLimitBackoff.refused(url, 30_000L + 12 * min))
    }

    @Test
    fun `refusals long after the last hold start the ladder over`() {
        val url = "wss://relay.example.com"
        RateLimitBackoff.refused(url, 0)
        RateLimitBackoff.refused(url, 30_000L)
        val later = 30_000L + 2 * min + RateLimitBackoff.REFUSAL_FORGET_MS + 1
        assertEquals(30_000L, RateLimitBackoff.refused(url, later))
    }

    @Test
    fun `a refusal never shortens a 429 hold`() {
        RateLimitBackoff.limited("wss://relay.damus.io", 0)
        assertEquals(hour, RateLimitBackoff.refused("wss://relay.damus.io", 0))
        assertEquals(hour, RateLimitBackoff.remainingMs("wss://relay.damus.io", 0))
    }

    @Test
    fun `local and LAN hosts are never held for a refusal`() {
        assertEquals(0L, RateLimitBackoff.refused("ws://127.0.0.1:3355/inbox", 0))
        assertEquals(0L, RateLimitBackoff.refused("ws://192.168.1.20:3355", 0))
        assertEquals(0L, RateLimitBackoff.remainingMs("ws://127.0.0.1:3355/chat", 0))
    }

    @Test
    fun `a connection that stayed up clears a refusal hold`() {
        RateLimitBackoff.refused("wss://relay.example.com", 0)
        RateLimitBackoff.recovered("wss://relay.example.com")
        assertEquals(0L, RateLimitBackoff.remainingMs("wss://relay.example.com", 0))
    }
}
