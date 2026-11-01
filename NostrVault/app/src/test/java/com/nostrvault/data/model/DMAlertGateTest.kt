package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A gift wrap never alerts before it is unlocked, and never for a DM written by
 * any account on this device (Logen 2026-11-01). Same cases as iOS DMAlertGateTests.
 */
class DMAlertGateTest {
    private val owner = "a".repeat(64)
    private val second = "b".repeat(64)
    private val friend = "c".repeat(64)
    private val own = setOf(owner, second)

    private fun alerts(
        sender: String, isFromMe: Boolean = false, blocked: Set<String> = emptySet(),
        inInbox: Boolean = true, onScreen: Boolean = false,
    ) = DMAlertGate.alerts(sender, isFromMe, own, blocked, inInbox, onScreen)

    @Test fun `a message from someone else alerts`() = assertTrue(alerts(friend))

    @Test fun `your own copy never alerts`() = assertFalse(alerts(owner, isFromMe = true))

    @Test
    fun `a self-copy from a non-active account never alerts`() {
        // The inbox that opened it doesn't call it "from me", but it is one of ours.
        assertFalse(alerts(second, isFromMe = false))
        assertFalse(alerts(second.uppercase(), isFromMe = false))
    }

    @Test
    fun `blocked, requests and the open thread don't alert`() {
        assertFalse(alerts(friend, blocked = setOf(friend)))
        assertFalse(alerts(friend, inInbox = false))
        assertFalse(alerts(friend, onScreen = true))
        assertFalse(alerts(""))
    }

    @Test
    fun `a wrap waits until it is unlocked, however slow the signer`() {
        val pending = PendingDMAlerts<String>()
        pending.add("wrap1", "npub-owner")
        assertEquals(1, pending.size)
        assertEquals("npub-owner", pending.take("wrap1"))
        assertNull(pending.take("wrap1"))
        // An event no alert waited for (a backlog wrap) decides nothing.
        assertNull(pending.take("other"))
    }

    @Test
    fun `a marker seen twice waits once`() {
        val pending = PendingDMAlerts<String>()
        pending.add("wrap1", "first")
        pending.add("wrap1", "second")
        assertEquals(1, pending.size)
        assertEquals("first", pending.take("wrap1"))
    }

    @Test
    fun `the queue drops the oldest past its limit`() {
        val pending = PendingDMAlerts<Int>(limit = 2)
        pending.add("w1", 1); pending.add("w2", 2); pending.add("w3", 3)
        assertEquals(2, pending.size)
        assertNull(pending.take("w1"))
        assertEquals(3, pending.take("w3"))
    }
}
