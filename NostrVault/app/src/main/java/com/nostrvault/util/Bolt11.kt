package com.nostrvault.util

/**
 * What a BOLT-11 invoice says it will cost.
 *
 * The distinction between "no amount" and "cannot read it" matters at a
 * payment confirmation: the first is a legal invoice where the payer's wallet
 * chooses the number, the second is a string this app cannot vouch for. Both
 * used to collapse into `null`, which is fine for displaying a zap receipt and
 * useless for warning someone before they spend.
 */
sealed interface Bolt11Amount {
    data class Sats(val sats: Long) : Bolt11Amount

    /** A valid invoice that names no amount — the paying wallet decides. */
    data object Unspecified : Bolt11Amount

    /** Not an invoice this app can read. */
    data object Unreadable : Bolt11Amount
}

/**
 * Reads the amount out of the human-readable part of a BOLT-11 invoice.
 *
 * Integer msat throughout: in floating point 90n comes out as
 * 9.000000000000002 sats.
 *
 * Reading only. An invoice this app cannot parse is still payable — the wallet
 * on the other end is the authority on that, not us — so callers should warn
 * rather than block.
 */
object Bolt11 {

    /**
     * `lnbc330n1…` is 330 nano-BTC, which is 33 sats. The trailing `1` is the
     * bech32 separator, and the regex backtracks onto it: in `lnbc11p…` the
     * amount is 1 BTC and the second `1` separates, not 11 pico-BTC.
     *
     * One ambiguity this cannot resolve without full bech32 validation: a
     * malformed multiplier (`lnbc1a1…`) backtracks to the same shape as a
     * genuinely amountless invoice, so it reads as [Bolt11Amount.Unspecified].
     * Both end the same way — the wallet is asked and decides.
     */
    private val PREFIX = Regex("""^ln(?:bc|tb|bcrt)(\d*)([munp]?)1""")

    fun amount(invoice: String): Bolt11Amount = when (val p = parse(invoice)) {
        is Parsed.Msat -> Bolt11Amount.Sats(p.msat / 1000L)
        Parsed.Unspecified -> Bolt11Amount.Unspecified
        Parsed.Unreadable -> Bolt11Amount.Unreadable
    }

    /**
     * The exact amount in millisatoshis, or null for an amountless or
     * unreadable invoice. For checking an invoice against the amount that was
     * asked for — [amount] rounds down to whole sats, which would let a
     * service add up to 999 msat unnoticed.
     */
    fun msat(invoice: String): Long? {
        val p = parse(invoice) as? Parsed.Msat ?: return null
        return p.msat.takeIf { p.exact && it > 0 && it < MAX_MSAT }
    }

    /** 21 million BTC, in msat. */
    private const val MAX_MSAT = 21_000_000L * 100_000_000_000L

    /** `exact` is false for a pico amount that is not a whole msat. */
    private sealed interface Parsed {
        data class Msat(val msat: Long, val exact: Boolean) : Parsed
        data object Unspecified : Parsed
        data object Unreadable : Parsed
    }

    private fun parse(invoice: String): Parsed {
        val match = PREFIX.find(invoice.trim().lowercase()) ?: return Parsed.Unreadable
        val digits = match.groupValues[1]
        if (digits.isEmpty()) return Parsed.Unspecified

        val value = digits.toLongOrNull() ?: return Parsed.Unreadable
        // 1 BTC = 100_000_000_000 msat.
        val perUnit = when (match.groupValues[2]) {
            "m" -> 100_000_000L
            "u" -> 100_000L
            "n" -> 100L
            // pico-BTC is a tenth of a msat; a valid pico amount is a multiple of 10.
            "p" -> return Parsed.Msat(value / 10L, exact = value % 10L == 0L)
            "" -> 100_000_000_000L
            else -> return Parsed.Unreadable
        }
        // The amount comes off the wire and nothing upstream bounds its
        // length; Long multiplication would wrap silently.
        val msat = try { Math.multiplyExact(value, perUnit) } catch (_: ArithmeticException) {
            return Parsed.Unreadable
        }
        return Parsed.Msat(msat, exact = true)
    }

    /** Sats, or null when the invoice names no readable positive amount. */
    fun satsOrNull(invoice: String): Long? =
        (amount(invoice) as? Bolt11Amount.Sats)?.sats?.takeIf { it > 0 }
}
