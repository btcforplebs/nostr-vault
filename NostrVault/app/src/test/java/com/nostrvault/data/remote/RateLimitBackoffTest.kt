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
}
