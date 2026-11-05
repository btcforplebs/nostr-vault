package com.nostrvault.service

import com.nostrvault.relay.RelayDrainState
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** A backup or restore waits for the stopped relay to let go of the databases instead of failing. */
class ExclusiveDbOpTest {
    private val noPause: suspend (Long) -> Unit = {}

    @Test
    fun `waits out a long drain then runs once`() = runBlocking {
        var draining = true
        var waits = 0
        val lines = mutableListOf<String>()
        var runs = 0
        val code = ExclusiveDbOp.run(
            op = { runs++; if (draining) 1 else 0 },
            onStatus = { lines += it },
            isDraining = { draining },
            awaitDrained = { waits++; draining = false; RelayDrainState.Wait.DRAINED },
            pause = noPause,
        )
        assertEquals(0, code)
        assertEquals(1, runs)
        assertEquals(1, waits)
        assertEquals(listOf(ExclusiveDbOp.WAIT_LINE), lines)
    }

    @Test
    fun `a refusal before the drain starts is retried`() = runBlocking {
        // Go says "relay is running" (1) until StopRelayC begins, then drains.
        var calls = 0
        var draining = false
        val code = ExclusiveDbOp.run(
            op = { calls++; if (calls == 1) { draining = true; 1 } else 0 },
            isDraining = { draining },
            awaitDrained = { draining = false; RelayDrainState.Wait.DRAINED },
            pause = noPause,
        )
        assertEquals(0, code)
        assertEquals(2, calls)
    }

    @Test
    fun `not this vault's backup is not retried`() = runBlocking {
        var calls = 0
        val code = ExclusiveDbOp.run(op = { calls++; 2 }, isDraining = { false }, pause = noPause)
        assertEquals(2, code)
        assertEquals(1, calls)
    }

    @Test
    fun `a drain that never ends runs nothing`() = runBlocking {
        var calls = 0
        val code = ExclusiveDbOp.run(
            op = { calls++; 0 },
            isDraining = { true },
            awaitDrained = { RelayDrainState.Wait.TIMED_OUT },
            pause = noPause,
        )
        assertEquals(ExclusiveDbOp.DRAIN_TIMEOUT_CODE, code)
        assertEquals(0, calls)
    }

    @Test
    fun `a failure that keeps coming stops after the last attempt`() = runBlocking {
        var calls = 0
        val code = ExclusiveDbOp.run(op = { calls++; 1 }, isDraining = { false }, pause = noPause)
        assertEquals(1, code)
        assertEquals(ExclusiveDbOp.ATTEMPTS, calls)
        assertTrue(ExclusiveDbOp.ATTEMPTS > 2)
    }
}
