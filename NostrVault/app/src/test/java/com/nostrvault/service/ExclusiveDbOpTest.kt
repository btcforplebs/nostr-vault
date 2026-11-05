package com.nostrvault.service

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** A backup or restore waits for the stopped relay to let go of the databases, however long that takes. */
class ExclusiveDbOpTest {
    @Test
    fun `waits out a drain longer than three minutes then runs once`() = runBlocking {
        // Logen's Moto took 3:10 (2026-11-05); a capped wait gave up at 3:00.
        var waitedMs = 0L
        val drainMs = 10 * 60_000L
        val lines = mutableListOf<String>()
        var runs = 0
        val code = ExclusiveDbOp.run(
            op = { runs++; if (waitedMs < drainMs) 1 else 0 },
            onStatus = { lines += it },
            isDraining = { waitedMs < drainMs },
            pause = { waitedMs += it },
        )
        assertEquals(0, code)
        assertEquals(1, runs)
        assertTrue(waitedMs >= drainMs)
        assertEquals(listOf(ExclusiveDbOp.STOPPING_LINE), lines)
    }

    @Test
    fun `a refusal before the drain starts is retried`() = runBlocking {
        // Go says "relay is running" (1) until StopRelayC begins, then drains.
        var calls = 0
        var drainLeft = 0
        val code = ExclusiveDbOp.run(
            op = { calls++; if (calls == 1) { drainLeft = 3; 1 } else 0 },
            isDraining = { drainLeft > 0 },
            pause = { if (drainLeft > 0) drainLeft-- },
        )
        assertEquals(0, code)
        assertEquals(2, calls)
    }

    @Test
    fun `not this vault's backup is not retried`() = runBlocking {
        var calls = 0
        val code = ExclusiveDbOp.run(op = { calls++; 2 }, isDraining = { false }, pause = {})
        assertEquals(2, code)
        assertEquals(1, calls)
    }

    @Test
    fun `a failure that keeps coming stops after the last attempt`() = runBlocking {
        var calls = 0
        val code = ExclusiveDbOp.run(op = { calls++; 1 }, isDraining = { false }, pause = {})
        assertEquals(1, code)
        assertEquals(ExclusiveDbOp.ATTEMPTS, calls)
    }

    @Test
    fun `no line when nothing drains`() = runBlocking {
        val lines = mutableListOf<String>()
        ExclusiveDbOp.run(op = { 0 }, onStatus = { lines += it }, isDraining = { false }, pause = {})
        assertTrue(lines.isEmpty())
    }
}
