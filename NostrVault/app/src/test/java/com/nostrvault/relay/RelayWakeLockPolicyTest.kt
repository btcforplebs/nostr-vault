package com.nostrvault.relay

import com.nostrvault.relay.RelayForegroundService.LifecycleState
import org.junit.Assert.assertEquals
import org.junit.Test

class RelayWakeLockPolicyTest {
    @Test
    fun `held only while the relay boots, stops, or serves the mesh`() {
        val expected = mapOf(
            (LifecycleState.IDLE to false) to false,
            (LifecycleState.IDLE to true) to false,
            (LifecycleState.BOOTING to false) to true,
            (LifecycleState.STOPPING to false) to true,
            (LifecycleState.RUNNING to false) to false,
            (LifecycleState.RUNNING to true) to true,
        )
        for ((input, hold) in expected) {
            assertEquals("$input", hold, RelayWakeLockPolicy.shouldHold(input.first, input.second))
        }
    }
}
