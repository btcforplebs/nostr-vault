package com.nostrvault.fips

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Lanes to the owner's other devices retry within about 2 minutes and right away when the device comes into reach;
 * the always-on mobile vault keeps its long backoff (Logen 2026-11-13). As iOS HomeVaultLaneBackoffTests.
 */
class HomeVaultLaneBackoffTest {
    private val t0 = 1_000_000L

    /** Tron M1 (#2005): a RETRY is recorded only after the device's door answered, so it backs off as before #2005. */
    @Test
    fun `an answered lane retry goes back to the long backoff`() {
        var it = HomeVaultQueue.Item(key = "k", type = HomeVaultQueue.TYPE_BLOB, queuedAt = t0)
        repeat(6) { _ -> it = HomeVaultRules.afterRetry(it, t0, lane = true) }
        assertEquals(t0 + 32 * 60_000L, it.nextAt)
        assertEquals(6, it.answered)
        repeat(20) { _ -> it = HomeVaultRules.afterRetry(it, t0, lane = true) }
        assertEquals(t0 + 6 * 60 * 60_000L, it.nextAt)
    }

    @Test
    fun `old tries from the 2-minute build do not inflate the answered backoff`() {
        val fromB28 = HomeVaultQueue.Item(key = "k", type = HomeVaultQueue.TYPE_BLOB, queuedAt = t0, attempts = 300)
        assertEquals(t0 + 60_000L, HomeVaultRules.afterRetry(fromB28, t0, lane = true).nextAt)
    }

    @Test
    fun `the mobile vault keeps its backoff`() {
        var it = HomeVaultQueue.Item(key = "k", type = HomeVaultQueue.TYPE_BLOB, queuedAt = t0)
        repeat(6) { _ -> it = HomeVaultRules.afterRetry(it, t0, lane = false) }
        assertEquals(t0 + 32 * 60_000L, it.nextAt)
        assertEquals(6, it.attempts)
    }

    @Test
    fun `only the mobile vault is not a lane`() {
        assertFalse(HomeVaultRules.isLane(DeviceRole.HOME_VAULT))
        assertTrue(HomeVaultRules.isLane(DeviceRole.MAC))
        assertTrue(HomeVaultRules.isLane(DeviceRole.PHONE))
    }

    @Test
    fun `a lane gives up after forty answered tries or on age`() {
        val now = 100L * 24 * 60 * 60_000L
        val tried = HomeVaultQueue.Item(key = "k", type = HomeVaultQueue.TYPE_BLOB, queuedAt = now, attempts = 400)
        assertFalse("tries from before this rule are not answers", HomeVaultRules.expired(tried, now, lane = true))
        assertTrue(HomeVaultRules.expired(tried.copy(answered = 40), now, lane = true))
        assertTrue(HomeVaultRules.expired(tried, now, lane = false))
        val old = HomeVaultQueue.Item(key = "k", type = HomeVaultQueue.TYPE_BLOB, queuedAt = now - 15L * 24 * 60 * 60_000L, attempts = 1)
        assertTrue(HomeVaultRules.expired(old, now, lane = true))
    }

    @Test
    fun `a device coming into reach makes its waiting items due now`() {
        val waiting = HomeVaultQueue.Item(key = "k", type = HomeVaultQueue.TYPE_BLOB, attempts = 3, nextAt = 9_999_999L)
        val due = HomeVaultQueue.Item(key = "d", type = HomeVaultQueue.TYPE_BLOB)
        assertEquals(listOf(waiting.copy(nextAt = 0)), HomeVaultRules.wokenOnReach(listOf(waiting, due)))
    }

    @Test
    fun `newly in reach is only what just connected`() {
        assertEquals(setOf("p"), HomeVaultRules.newlyInReach(now = setOf("p", "m"), before = setOf("m")))
        assertEquals(emptySet<String>(), HomeVaultRules.newlyInReach(now = setOf("m"), before = setOf("m", "p")))
    }
}
