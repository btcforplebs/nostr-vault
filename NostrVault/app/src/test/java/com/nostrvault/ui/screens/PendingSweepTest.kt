package com.nostrvault.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The confirm step only opens for a sweep that may be sent, and shows what will be sent. */
class PendingSweepTest {
    private val taproot = "bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr"

    @Test fun confirmShowsTheTrimmedAddressAmountAndFee() {
        val sweep = PendingSweep.from(" $taproot\n", balanceSats = 100_000, feeRate = 10)
        assertEquals(PendingSweep(taproot, feeRate = 10, amount = 100_000 - 1_110, fee = 1_110), sweep)
    }

    @Test fun noConfirmForABadAddress() {
        assertNull(PendingSweep.from("bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcs", 100_000, 10))
        assertNull(PendingSweep.from("tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx", 100_000, 10))
        assertNull(PendingSweep.from("", 100_000, 10))
    }

    @Test fun noConfirmWhenWhatIsLeftIsDust() {
        assertNull(PendingSweep.from(taproot, balanceSats = 111 * 5 + 546, feeRate = 5))
        assertEquals(547L, PendingSweep.from(taproot, balanceSats = 111 * 5 + 547, feeRate = 5)?.amount)
        assertNull(PendingSweep.from(taproot, balanceSats = null, feeRate = 5))
    }
}
