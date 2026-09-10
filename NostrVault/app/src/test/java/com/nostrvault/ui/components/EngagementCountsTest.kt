package com.nostrvault.ui.components

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class EngagementCountsTest {

    @Test
    fun `formats counts compactly across every threshold`() {
        assertEquals("0", formatCount(0))
        assertEquals("999", formatCount(999))
        assertEquals("1.0k", formatCount(1000))
        assertEquals("1.2k", formatCount(1234))
        assertEquals("9.9k", formatCount(9949))
        assertEquals("10k", formatCount(10_000))
        assertEquals("999k", formatCount(999_999))
        assertEquals("1.0M", formatCount(1_000_000))
        assertEquals("2.4M", formatCount(2_400_000))
        assertEquals("21M", formatCount(21_000_000))
    }

    @Test
    fun `zero draws nothing rather than a zero`() {
        assertNull(engagementCountLabel(0))
        assertEquals("1", engagementCountLabel(1))
    }

    @Test
    fun `a negative count from a raced optimistic decrement draws nothing`() {
        assertNull(engagementCountLabel(-1))
    }

    @Test
    fun `zap label prefers the sats amount over the number of zappers`() {
        assertEquals("2.1k", zapCountLabel(zapCount = 3, zapAmountSats = 2100L))
    }

    @Test
    fun `zap label falls back to the count when the invoice carried no amount`() {
        assertEquals("3", zapCountLabel(zapCount = 3, zapAmountSats = 0L))
    }

    @Test
    fun `an unzapped note draws nothing`() {
        assertNull(zapCountLabel(zapCount = 0, zapAmountSats = 0L))
    }

    @Test
    fun `a sats total past Int range does not overflow into a negative`() {
        // 3 BTC in sats is well past Int.MAX_VALUE. Narrowing to Int anywhere on
        // this path wraps and prints a negative number.
        assertEquals("300M", zapCountLabel(zapCount = 1, zapAmountSats = 300_000_000L))
        assertEquals("2.1B", zapCountLabel(zapCount = 1, zapAmountSats = 2_100_000_000L))
    }
}
