package com.nostrvault.util

import org.junit.Assert.assertEquals
import org.junit.Test

/** Zap sats: the request's amount, then the receipt's, then the invoice (iOS 5f866a93). */
class ZapAmountTest {
    private fun request(amountMsat: String?): String {
        val amount = amountMsat?.let { ""","tags":[["amount","$it"]]""" } ?: ""","tags":[]"""
        return """{"kind":9734,"pubkey":"${"a".repeat(64)}","content":""$amount}"""
    }

    @Test fun `request without an amount reads the invoice`() {
        val tags = listOf(listOf("bolt11", "lnbc2500u1pvjluezpp5abcdef"), listOf("description", request(null)))
        assertEquals(250_000L, ZapAmount.sats(tags))
    }

    @Test fun `request amount wins over the invoice`() {
        val tags = listOf(listOf("bolt11", "lnbc2500u1pvjluezpp5abcdef"), listOf("description", request("21000")))
        assertEquals(21L, ZapAmount.sats(tags))
    }

    @Test fun `receipt amount is the second rung`() {
        val tags = listOf(listOf("amount", "5000"), listOf("description", request(null)))
        assertEquals(5L, ZapAmount.sats(tags))
    }

    @Test fun `nothing readable is zero`() {
        assertEquals(0L, ZapAmount.sats(listOf(listOf("description", "not json"))))
    }
}
