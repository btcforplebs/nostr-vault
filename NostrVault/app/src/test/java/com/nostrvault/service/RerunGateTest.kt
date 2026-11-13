package com.nostrvault.service

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Tron #2012 follow-up: one WoT load at a time, and a call mid-run gets one more run, not a restart. */
class RerunGateTest {
    @Test fun `first call starts, calls during a run do not`() {
        val gate = RerunGate()
        assertTrue(gate.tryStart())
        assertFalse(gate.tryStart())
        assertFalse(gate.tryStart())
    }

    @Test fun `calls during a run mean exactly one more run`() {
        val gate = RerunGate()
        gate.tryStart()
        repeat(20) { gate.tryStart() }
        assertTrue(gate.finish()) // the rerun, already running
        assertFalse(gate.tryStart()) // still running
        assertTrue(gate.finish()) // that call asked again
        assertFalse(gate.finish()) // idle now
        assertTrue(gate.tryStart())
    }

    @Test fun `a quiet run ends and the next call starts fresh`() {
        val gate = RerunGate()
        assertTrue(gate.tryStart())
        assertFalse(gate.finish())
        assertTrue(gate.tryStart())
    }

    @Test fun `many threads start at most one run at a time`() {
        val gate = RerunGate()
        val started = java.util.concurrent.atomic.AtomicInteger()
        val threads = (1..16).map { Thread { repeat(1000) { if (gate.tryStart()) started.incrementAndGet() } } }
        threads.forEach { it.start() }; threads.forEach { it.join() }
        assertTrue(started.get() == 1)
    }
}
