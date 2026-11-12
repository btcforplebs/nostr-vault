package com.nostrvault.fips

import org.junit.Assert.assertEquals
import org.junit.Test

/** Parity with iOS PulledInjectionTests: the second-hand mark on an own-device write address. */
class PulledInjectionTest {
    @Test
    fun `marks the address once and keeps the rest`() {
        assertEquals("ws://127.0.0.1:41234/0123456789abcdef?pulled=1", PulledInjection.url("ws://127.0.0.1:41234/0123456789abcdef"))
        assertEquals("ws://127.0.0.1:3355/?a=b&pulled=1", PulledInjection.url("ws://127.0.0.1:3355/?a=b&pulled=0"))
        assertEquals("ws://h/?pulled=1", PulledInjection.url("ws://h/?pulled=1"))
    }
}
