package com.nostrvault.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The confirm step only opens for a sweep that may be sent, and shows what will be sent. */
class PendingSweepTest {
    private val taproot = "bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr"

    @Test fun confirmShowsTheTrimmedAddressAmountAndFee() {
        val sweep = PendingSweep.from(" $taproot\n", balanceSats = 100_000, utxoCount = 1, feeRate = 10)
        assertEquals(PendingSweep(taproot, feeRate = 10, amount = 100_000 - 1_110, fee = 1_110), sweep)
    }

    @Test fun noConfirmForABadAddress() {
        assertNull(PendingSweep.from("bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcs", 100_000, 1, 10))
        assertNull(PendingSweep.from("tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx", 100_000, 1, 10))
        assertNull(PendingSweep.from("", 100_000, 1, 10))
    }

    @Test fun noConfirmWhenWhatIsLeftIsDust() {
        assertNull(PendingSweep.from(taproot, balanceSats = 111 * 5 + 546, utxoCount = 1, feeRate = 5))
        assertEquals(547L, PendingSweep.from(taproot, balanceSats = 111 * 5 + 547, utxoCount = 1, feeRate = 5)?.amount)
        assertNull(PendingSweep.from(taproot, balanceSats = null, utxoCount = 1, feeRate = 5))
    }

    /** haven-go/bitcoin.go estimateSweepVsize: ceil((4·(53+41n) + 2+66n) / 4). */
    @Test fun vsizeMatchesGoForEveryInputCount() {
        assertEquals(111L, PendingSweep.estimatedVsize(1))
        assertEquals(169L, PendingSweep.estimatedVsize(2))
        assertEquals(629L, PendingSweep.estimatedVsize(10))
        for (n in 1..200) {
            val weight = (10 + 41L * n + 43) * 4 + 2 + 66L * n
            assertEquals((weight + 3) / 4, PendingSweep.estimatedVsize(n))
        }
    }

    /** The sweep spends every output, so ten of them cost ten inputs' fee. */
    @Test fun feeAndAmountCountEveryUtxo() {
        val sweep = PendingSweep.from(taproot, balanceSats = 100_000, utxoCount = 10, feeRate = 10)
        assertEquals(PendingSweep(taproot, feeRate = 10, amount = 100_000 - 6_290, fee = 6_290), sweep)
        // Enough for one input's fee, dust after ten inputs'.
        assertNull(PendingSweep.from(taproot, balanceSats = 6_290 + 546, utxoCount = 10, feeRate = 10))
    }

    /** No count yet is treated as one input, never zero. */
    @Test fun zeroUtxosCountsAsOne() {
        assertEquals(111L, PendingSweep.estimatedVsize(0))
    }
}
