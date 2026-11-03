package com.nostrvault.shareportal

import com.nostrvault.util.findAllOnce

/**
 * What a "Pay or zap" share points at: the first invoice, else the first
 * LNURL, else the whole text when it is a lightning address. Pure; mirrors
 * PayShareTarget.swift and is tested with the same fixture
 * (pay-target-cases.json). The share sheet never sets an amount: the amount
 * comes from the invoice itself or from what the person types on the review
 * card.
 */
data class PayShareTarget(
    /** Lowercased, any `lightning:` prefix removed. */
    val token: String,
    val kind: Kind,
    /** The one npub the share also names, if exactly one. */
    val recipientNpub: String?,
) {
    enum class Kind(val raw: String) { INVOICE("invoice"), LNURL("lnurl"), ADDRESS("address") }

    companion object {
        // The classifier's own patterns (contract §3), so a share that offered
        // Pay always finds its target here.
        private const val BECH32 = "[qpzry9x8gf2tvdw0s3jn54khce6mua7l]"
        private val BOLT11 = Regex("""\b(?:lightning:)?ln(?:bc|tb|tbs|bcrt)[0-9a-z]{20,}\b""", RegexOption.IGNORE_CASE)
        private val LNURL = Regex("""\b(?:lightning:)?lnurl1[0-9a-z]{20,}\b""", RegexOption.IGNORE_CASE)
        private val LIGHTNING_ADDRESS = Regex(
            """^(?:lightning:)?[a-z0-9._-]+@[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,}$""", RegexOption.IGNORE_CASE,
        )
        private val NPUB = Regex("""\bnpub1$BECH32{58}\b""", RegexOption.IGNORE_CASE)

        fun find(url: String?, text: String?, selection: String?): PayShareTarget? {
            val haystack = listOfNotNull(url, text, selection).joinToString("\n")
            val npub = onlyNpub(haystack)
            BOLT11.find(haystack)?.let { return PayShareTarget(strip(it.value), Kind.INVOICE, npub) }
            LNURL.find(haystack)?.let { return PayShareTarget(strip(it.value), Kind.LNURL, npub) }
            val trimmed = text?.trim().orEmpty()
            if (trimmed.isNotEmpty() && trimmed.length <= 320 && LIGHTNING_ADDRESS.matches(trimmed)) {
                return PayShareTarget(strip(trimmed), Kind.ADDRESS, npub)
            }
            return null
        }

        /**
         * A zap is offered only when the shared address is the recipient's own
         * published one, so it can never route money somewhere their profile
         * does not already say.
         */
        fun canZap(target: PayShareTarget, profileLightningAddress: String?): Boolean {
            if (target.kind != Kind.ADDRESS || target.recipientNpub == null) return false
            val lud16 = profileLightningAddress?.trim()?.lowercase()?.takeIf { it.isNotEmpty() } ?: return false
            return lud16 == target.token
        }

        private fun strip(s: String): String = s.lowercase().removePrefix("lightning:")

        private fun onlyNpub(s: String): String? {
            // findAllOnce, not findAll: see RegexScanTest. Two different npubs are enough to answer.
            val found = NPUB.findAllOnce(s).map { it.value.lowercase() }.distinct().take(2).toList()
            return found.singleOrNull()
        }
    }
}
