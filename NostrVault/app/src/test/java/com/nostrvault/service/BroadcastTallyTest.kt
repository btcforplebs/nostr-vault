package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class BroadcastTallyTest {

    @Test
    fun `no relays is refused up front`() {
        assertEquals(BroadcastTally.Outcome.REFUSED, BroadcastTally(0).outcome)
    }

    @Test
    fun `first acceptance decides it`() {
        val tally = BroadcastTally(3)
        assertNull(tally.record("a", false, "blocked"))
        assertEquals(BroadcastTally.Outcome.ACCEPTED, tally.record("b", true, ""))
        // Later answers never change or repeat it.
        assertNull(tally.record("c", false, "timeout"))
        assertEquals(BroadcastTally.Outcome.ACCEPTED, tally.outcome)
    }

    @Test
    fun `refused only once every relay has answered`() {
        val tally = BroadcastTally(2)
        assertNull(tally.record("a", false, "timeout"))
        assertNull(tally.outcome)
        assertEquals(BroadcastTally.Outcome.REFUSED, tally.record("b", false, "connection failed"))
    }

    @Test
    fun `a repeated answer from one relay counts once`() {
        val tally = BroadcastTally(2)
        assertNull(tally.record("a", false, "timeout"))
        assertNull(tally.record("a", false, "timeout"))
        assertNull(tally.outcome)
    }

    @Test
    fun `duplicate refusal counts as accepted`() {
        val tally = BroadcastTally(2)
        assertEquals(BroadcastTally.Outcome.ACCEPTED, tally.record("a", false, "Duplicate: already have this event"))
    }
}
