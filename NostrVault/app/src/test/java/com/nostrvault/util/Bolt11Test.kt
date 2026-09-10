package com.nostrvault.util

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The wallet's payment confirmation reads its number from here, so the
 * distinction between "no amount" and "cannot read it" is the part that
 * matters — those two get different warnings, and neither may be reported as
 * a quantity.
 *
 * Amount vectors are the ones from [com.nostrvault.service.Bolt11AmountTest],
 * which came off real nos.lol zap receipts.
 */
class Bolt11Test {

    @Test fun `an amount is read as sats`() {
        assertEquals(Bolt11Amount.Sats(21L), Bolt11.amount("lnbc210n1p4fakabc"))
        assertEquals(Bolt11Amount.Sats(33L), Bolt11.amount("lnbc330n1p4fakabc"))
        assertEquals(Bolt11Amount.Sats(100_000L), Bolt11.amount("lnbc1m1p4fakabc"))
        assertEquals(Bolt11Amount.Sats(100L), Bolt11.amount("lnbc1u1p4fakabc"))
        // No multiplier at all: whole BTC. The second `1` is the bech32
        // separator, not part of an "11 pico" amount.
        assertEquals(Bolt11Amount.Sats(100_000_000L), Bolt11.amount("lnbc11p4fakabc"))
    }

    @Test fun `awkward amounts stay whole numbers`() {
        // In floating point these come out as 9.000000000000002 and
        // 7.000000000000001.
        assertEquals(Bolt11Amount.Sats(9L), Bolt11.amount("lnbc90n1p4fakabc"))
        assertEquals(Bolt11Amount.Sats(7L), Bolt11.amount("lnbc70n1p4fakabc"))
        assertEquals(Bolt11Amount.Sats(1L), Bolt11.amount("lnbc10n1p4fakabc"))
    }

    @Test fun `an amountless invoice is not an unreadable one`() {
        // Legal, and the payer's wallet chooses. Warned about, not blocked.
        assertEquals(Bolt11Amount.Unspecified, Bolt11.amount("lnbc1p4fakabc"))
        assertEquals(Bolt11Amount.Unspecified, Bolt11.amount("lntb1p4fakabc"))
    }

    @Test fun `a string that is not an invoice is unreadable`() {
        assertEquals(Bolt11Amount.Unreadable, Bolt11.amount("not-an-invoice"))
        assertEquals(Bolt11Amount.Unreadable, Bolt11.amount(""))
        // No bech32 separator after the human-readable part.
        assertEquals(Bolt11Amount.Unreadable, Bolt11.amount("lnbc330n"))
    }

    @Test fun `case and whitespace do not matter`() {
        assertEquals(Bolt11Amount.Sats(21L), Bolt11.amount("  LNBC210N1P4FAKABC  "))
    }

    @Test fun `satsOrNull reports nothing rather than zero`() {
        assertEquals(21L, Bolt11.satsOrNull("lnbc210n1p4fakabc"))
        assertEquals(null, Bolt11.satsOrNull("lnbc1p4fakabc"))
        assertEquals(null, Bolt11.satsOrNull("not-an-invoice"))
    }
}
