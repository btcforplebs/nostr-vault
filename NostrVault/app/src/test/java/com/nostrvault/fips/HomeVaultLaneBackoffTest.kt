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
    @Test
    fun `a lane's backoff stops at two minutes, the mobile vault's does not`() {
        assertEquals(60_000L, HomeVaultRules.backoffMs(1, lane = true))
        assertEquals(120_000L, HomeVaultRules.backoffMs(2, lane = true))
        assertEquals(120_000L, HomeVaultRules.backoffMs(6, lane = true))
        assertEquals(120_000L, HomeVaultRules.backoffMs(1000, lane = true))
        assertEquals(32 * 60_000L, HomeVaultRules.backoffMs(6, lane = false))
    }

    @Test
    fun `only the mobile vault is not a lane`() {
        assertFalse(HomeVaultRules.isLane(DeviceRole.HOME_VAULT))
        assertTrue(HomeVaultRules.isLane(DeviceRole.MAC))
        assertTrue(HomeVaultRules.isLane(DeviceRole.PHONE))
    }

    @Test
    fun `a lane gives up on age only, not on tries`() {
        val now = 100L * 24 * 60 * 60_000L
        val tried = HomeVaultQueue.Item(key = "k", type = HomeVaultQueue.TYPE_BLOB, queuedAt = now, attempts = 400)
        assertFalse(HomeVaultRules.expired(tried, now, lane = true))
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
