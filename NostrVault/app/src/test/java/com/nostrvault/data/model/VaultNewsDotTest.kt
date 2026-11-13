package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Test

class VaultNewsDotTest {
    private val alice = "a".repeat(64)
    private val bob = "b".repeat(64)

    private fun dot(account: String = alice) = VaultNewsDot().apply { switchAccount(account) }

    @Test
    fun `with nothing reading the inbox the relay line lights the list`() {
        val dot = dot()
        dot.land(VaultMode.LIKES)
        assertEquals(setOf(VaultMode.LIKES), dot.modes.value)
    }

    @Test
    fun `while the list reads, a line only proposes - an old catch-up does not light`() {
        val dot = dot()
        dot.setJudged(true)
        dot.land(VaultMode.LIKES)
        assertEquals(emptySet<VaultMode>(), dot.modes.value)
        dot.settle(dot.proposed(), alice) { false }
        assertEquals(emptySet<VaultMode>(), dot.modes.value)
        assertEquals(emptySet<VaultMode>(), dot.proposed())
    }

    @Test
    fun `a proposal with real news lights its list`() {
        val dot = dot()
        dot.setJudged(true)
        dot.land(VaultMode.ZAPS)
        dot.land(VaultMode.LIKES)
        dot.settle(dot.proposed(), alice) { it == VaultMode.ZAPS }
        assertEquals(setOf(VaultMode.ZAPS), dot.modes.value)
    }

    @Test
    fun `a proposal made after the read began waits for the next read`() {
        val dot = dot()
        dot.setJudged(true)
        dot.land(VaultMode.LIKES)
        val asked = dot.proposed()
        dot.land(VaultMode.NOTES)
        dot.settle(asked, alice) { true }
        assertEquals(setOf(VaultMode.LIKES), dot.modes.value)
        assertEquals(setOf(VaultMode.NOTES), dot.proposed())
    }

    @Test
    fun `a read for an account switched away from lights nothing`() {
        val dot = dot()
        dot.setJudged(true)
        dot.land(VaultMode.LIKES)
        val asked = dot.proposed()
        dot.switchAccount(bob)
        dot.settle(asked, alice) { true }
        assertEquals(emptySet<VaultMode>(), dot.modes.value)
    }

    @Test
    fun `when nothing reads any more, proposals light as before`() {
        val dot = dot()
        dot.setJudged(true)
        dot.land(VaultMode.NOTES)
        dot.setJudged(false)
        assertEquals(setOf(VaultMode.NOTES), dot.modes.value)
    }

    @Test
    fun `each account keeps its own dot`() {
        val dot = dot()
        dot.land(VaultMode.LIKES)
        dot.switchAccount(bob)
        assertEquals(emptySet<VaultMode>(), dot.modes.value)
        dot.land(VaultMode.ZAPS)
        dot.switchAccount(alice.uppercase())
        assertEquals(setOf(VaultMode.LIKES), dot.modes.value)
        dot.switchAccount(bob)
        assertEquals(setOf(VaultMode.ZAPS), dot.modes.value)
    }

    @Test
    fun `seeing Vault clears every list, seeing one list clears it`() {
        val dot = dot()
        dot.land(VaultMode.LIKES)
        dot.land(VaultMode.ZAPS)
        dot.viewed(VaultMode.LIKES)
        assertEquals(setOf(VaultMode.ZAPS), dot.modes.value)
        dot.viewed(VaultMode.ACTIVITY)
        assertEquals(emptySet<VaultMode>(), dot.modes.value)
    }
}
