package com.nostrvault.data.remote

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** A relay that accepts and then drops must not reset the redial backoff. */
class ReconnectBackoffResetTest {
    @Test fun `a socket that stayed up a minute starts the backoff over`() {
        assertTrue(WebSocketClient.stayedUp(openedAtMs = 1_000L, nowMs = 61_000L))
    }

    @Test fun `a socket dropped within a minute keeps backing off`() {
        assertFalse(WebSocketClient.stayedUp(openedAtMs = 1_000L, nowMs = 2_000L))
        assertFalse(WebSocketClient.stayedUp(openedAtMs = 1_000L, nowMs = 60_999L))
    }

    @Test fun `a socket that never opened keeps backing off`() {
        assertFalse(WebSocketClient.stayedUp(openedAtMs = 0L, nowMs = 1_000_000L))
    }
}
