package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Same cases as MarketConduitTests.swift: Conduit listings (client tag "Conduit Merchant Portal") buy on
 * Conduit by coordinate; every other listing keeps Plebeian. Shapes from the live capture in
 * RESEARCH/NV_CONDUIT_BUY_LINK_2026_11_26.md.
 */
class MarketConduitTest {
    private val handler = "31990:" + "f".repeat(64) + ":conduit-merchant"
    private val seller = "5".repeat(64)
    private val eventId = "4".repeat(64)

    private fun listing(tags: List<List<String>>, kind: Int = 30402) = MarketListing.parse(
        eventId, seller, kind, "Hoodie", 1_790_000_000,
        listOf(listOf("title", "Genesis XXI Hoodie"), listOf("image", "https://img/h.jpg"), listOf("price", "60", "USD")) + tags,
    )!!

    @Test fun `client tag by name or handler address`() {
        assertTrue(MarketListing.isConduit(listOf(listOf("client", "Conduit Merchant Portal", handler, "wss://relay.conduit.market"))))
        assertTrue(MarketListing.isConduit(listOf(listOf("client", "Conduit Merchant Portal"))))
        assertTrue(MarketListing.isConduit(listOf(listOf("client", "Renamed", handler))))
        assertFalse(MarketListing.isConduit(listOf(listOf("client", "Shopstr", "31990:$seller:shopstr"))))
        assertFalse(MarketListing.isConduit(listOf(listOf("t", "conduit"), listOf("r", "wss://relay.conduit.market"))))
    }

    @Test fun `Conduit listing buys on Conduit by coordinate`() {
        val l = listing(listOf(listOf("d", "hoodie-2xl"), listOf("client", "Conduit Merchant Portal", handler)))
        assertEquals("Buy on Conduit", l.buyLink.label)
        assertEquals("https://shop.conduit.market/products/30402%3A$seller%3Ahoodie-2xl", l.buyLink.url)
        assertEquals("Hi! I'm interested in “Genesis XXI Hoodie”.\n${l.buyLink.url}", l.messageToSeller)
    }

    @Test fun `no d tag uses the event id`() {
        val l = listing(listOf(listOf("client", "Conduit Merchant Portal")))
        assertEquals("https://shop.conduit.market/products/$eventId", l.buyLink.url)
    }

    @Test fun `other listings keep Plebeian`() {
        val l = listing(listOf(listOf("d", "x"), listOf("client", "Shopstr")))
        assertEquals(MarketListing.BuyLink("Plebeian", "https://plebeian.market/products/$eventId", true), l.buyLink)
        assertEquals("Buy on Plebeian", l.buyLink.label)
    }
}
