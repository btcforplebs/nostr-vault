package com.nostrvault.util

/**
 * Lightning invoices pasted into a note, so the feed can draw each as a card
 * you can pay instead of a wall of bech32. Port of iOS NoteInvoices.swift and
 * the card half of Bolt11.swift (#1241).
 */
object NoteInvoices {

    /** One invoice as it sits in the note. */
    data class Match(
        /** Exactly as written (`lightning:` prefix and case included), so it can be cut out of the text. */
        val raw: String,
        /** Lowercased and prefix-free: what the wallet is handed. */
        val invoice: String,
        val details: Bolt11Details,
    )

    // Network prefix, optional amount, separator, then a data part long enough
    // to hold a timestamp and a signature. Case-insensitive: bech32 may be
    // written all upper-case, which QR codes favour.
    private val REGEX = Regex(
        """(?<![0-9a-z])(?:lightning:(?://)?)?(ln(?:bcrt|bc|tbs|tb)[0-9]*[munp]?1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{117,})(?![0-9a-z])""",
        RegexOption.IGNORE_CASE,
    )

    /** Every readable invoice in [content], in order, each once. Text that only looks like an invoice stays text. */
    fun find(content: String): List<Match> {
        // Most notes have none; skip the regex for them.
        if (!content.contains("ln", ignoreCase = true)) return emptyList()
        val seen = HashSet<String>()
        return REGEX.findAllOnce(content).mapNotNull { m ->
            val invoice = m.groupValues[1].lowercase()
            if (!seen.add(invoice)) return@mapNotNull null
            val details = Bolt11Details.read(invoice) ?: return@mapNotNull null
            Match(raw = m.value, invoice = invoice, details = details)
        }.toList()
    }

    /** [content] with the given invoices cut out, every time each appears, the way media URLs are cut for their thumbnails. */
    fun strip(matches: List<Match>, content: String): String {
        if (matches.isEmpty()) return content
        val cut = matches.mapTo(HashSet()) { it.invoice }
        return REGEX.replace(content) { m -> if (m.groupValues[1].lowercase() in cut) "" else m.value }
    }

    /** The note's text once its invoices are cards: [strip], without the run of empty lines each one leaves behind. */
    fun textWithout(matches: List<Match>, content: String): String {
        if (matches.isEmpty()) return content
        return strip(matches, content).replace(Regex("[ \t]+\n"), "\n").replace(Regex("\n{3,}"), "\n\n").trim()
    }
}

/** Everything an invoice card needs: what it costs, what it is for, and whether it can still be paid. */
data class Bolt11Details(
    val amount: Bolt11Amount,
    /** The `d` field, the payee's own words. Null when empty or absent (a hashed `h` description says nothing a person can read). */
    val memo: String?,
    /** Unix seconds. */
    val createdAt: Long,
    val expiresAt: Long,
) {
    fun isExpired(nowSeconds: Long = System.currentTimeMillis() / 1000) = nowSeconds >= expiresAt

    companion object {
        /** BOLT-11: an invoice with no `x` field expires an hour after it was made. */
        const val DEFAULT_EXPIRY = 3600L

        private const val CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

        /**
         * Reads amount, memo and expiry. Null for anything that is not an
         * invoice we can read: the feed shows such text as text rather than a
         * card that cannot say what it costs or when it lapses. Checksum is
         * not verified; the wallet checks the invoice it is asked to pay.
         */
        fun read(invoice: String): Bolt11Details? {
            val amount = Bolt11.amount(invoice)
            if (amount == Bolt11Amount.Unreadable) return null
            val words = dataWords(invoice) ?: return null
            if (words.size <= 7 + 104 + 6) return null

            val timestamp = (0 until 7).fold(0L) { acc, i -> (acc shl 5) or words[i].toLong() }
            var memo: String? = null
            var expiry = DEFAULT_EXPIRY
            val end = words.size - 104 - 6
            var i = 7
            while (i + 3 <= end) {
                val type = words[i]
                val length = (words[i + 1] shl 5) or words[i + 2]
                i += 3
                if (i + length > end) return null
                val field = words.subList(i, i + length)
                when (CHARSET[type]) {
                    'd' -> memo = String(bytes(field), Charsets.UTF_8).trim().ifEmpty { null }
                    // A field longer than a Long can hold is junk; keep the default.
                    'x' -> if (length <= 12) expiry = field.fold(0L) { acc, w -> (acc shl 5) or w.toLong() }
                }
                i += length
            }
            return Bolt11Details(amount, memo, timestamp, timestamp + expiry)
        }

        /** The data part as 5-bit words, or null when it holds a character bech32 does not use. */
        private fun dataWords(invoice: String): List<Int>? {
            val lower = invoice.trim().lowercase()
            val separator = lower.lastIndexOf('1')
            if (separator < 0) return null
            return lower.substring(separator + 1).map { ch -> CHARSET.indexOf(ch).takeIf { it >= 0 } ?: return null }
        }

        /** 5-bit words to bytes, dropping the padding bits at the end. */
        private fun bytes(words: List<Int>): ByteArray {
            val out = ArrayList<Byte>()
            var acc = 0
            var bits = 0
            for (w in words) {
                acc = (acc shl 5) or w
                bits += 5
                if (bits >= 8) {
                    bits -= 8
                    out.add(((acc shr bits) and 0xff).toByte())
                    acc = acc and ((1 shl bits) - 1)
                }
            }
            return out.toByteArray()
        }
    }
}
