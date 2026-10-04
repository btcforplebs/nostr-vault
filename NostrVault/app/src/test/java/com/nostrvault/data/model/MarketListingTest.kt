package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Same cases as MarketListingTests.swift. Event shapes captured from
 * nostr.wine, relay.damus.io and relay.primal.net on 2026-10-04.
 */
class MarketListingTest {

    private fun listing(kind: Int, content: String, tags: List<List<String>>) =
        MarketListing.parse("id1", "pk1", kind, content, 1_790_000_000, tags)

    @Test fun `tag-shaped zap cooking product`() {
        val l = listing(30018, "reverse osmosis", listOf(
            listOf("d", "fe8beb74-d1ad-414d-bcbc-e980b4784e96"), listOf("title", "Water"),
            listOf("summary", "Bottle of Water"), listOf("price", "1000", "SAT"), listOf("t", "ingredients"),
            listOf("status", "active"), listOf("image", "https://i.nostr.build/leUHRTQsC4lZHPkp.jpg"),
            listOf("location", "USA"),
        ))!!
        assertEquals("Water", l.title)
        assertEquals("Bottle of Water", l.summary)
        assertEquals("1,000 sats", l.priceLabel)
        assertEquals("USA", l.location)
        assertEquals("fe8beb74-d1ad-414d-bcbc-e980b4784e96", l.dTag)
        assertEquals("https://i.nostr.build/leUHRTQsC4lZHPkp.jpg", l.coverImage)
        assertFalse(l.isAuction)
    }

    @Test fun `NIP-15 JSON product`() {
        val content = """{"id":"christmas-baking-j99b2pic5f","name":"Christmas Baking","description":"A selection of traditional Christmas cookies","images":["https://image.nostr.build/ace2.jpg"],"price":21000,"quantity":21,"currency":"SATS"}"""
        val l = listing(30018, content, listOf(listOf("d", "christmas-baking-j99b2pic5f"), listOf("t", "Baking")))!!
        assertEquals("Christmas Baking", l.title)
        assertEquals("A selection of traditional Christmas cookies", l.summary)
        assertEquals("21000", l.price)
        assertEquals("21,000 sats", l.priceLabel)
        assertEquals("https://plebeian.market/products/id1", l.plebeianUrl)
    }

    @Test fun `Conduit JSON classified`() {
        val content = """{"title":"Mug","summary":"Orange mug","price":2,"currency":"USD","images":[{"url":"https://shop.conduit.market/mug.jpg"}]}"""
        val l = listing(30402, content, listOf(listOf("d", "mug")))!!
        assertEquals("Mug", l.title)
        assertEquals("Orange mug", l.summary)
        assertEquals("https://shop.conduit.market/mug.jpg", l.coverImage)
        assertEquals("2 USD", l.priceLabel)
    }

    @Test fun `fiat price and auction`() {
        val classified = listing(30402, "Long markdown body", listOf(
            listOf("title", "John Deere 1214 Crimper"), listOf("image", "https://i.nostr.build/jpy.jpg"),
            listOf("price", "1000", "CAD"),
        ))!!
        assertEquals("1000 CAD", classified.priceLabel)
        assertEquals("Long markdown body", classified.summary)

        val auction = listing(30020, """{"name":"Rare coin","images":["https://x.example/c.jpg"],"starting_bid":5000}""", emptyList())!!
        assertTrue(auction.isAuction)
        assertEquals("5,000 sats", auction.priceLabel)
        assertEquals("https://plebeian.market/auction/id1", auction.plebeianUrl)
    }

    @Test fun `rejects what cannot be shown or bought`() {
        val image = listOf("image", "https://x.example/a.jpg")
        assertNull(listing(30402, "", listOf(listOf("title", "No photo"))))
        assertNull(listing(30402, "", listOf(image)))
        assertNull(listing(30402, "", listOf(listOf("title", "Untitled Product"), image)))
        assertNull(listing(30402, "", listOf(listOf("title", "Ouroboros"), image, listOf("status", "sold"))))
        assertNull(listing(30402, "", listOf(listOf("title", "Gone"), image, listOf("visibility", "hidden"))))
        assertNull(listing(30402, "", listOf(listOf("title", "FTP"), listOf("image", "ftp://x/a.jpg"))))
        assertNull(listing(1, "", listOf(listOf("title", "Note"), image)))
        assertNotNull(listing(30402, "", listOf(listOf("title", "Fine"), image, listOf("status", "active"))))
    }

    @Test fun `missing price shows question mark`() {
        val l = listing(30402, "", listOf(listOf("title", "Ask me"), listOf("image", "https://x.example/a.jpg")))!!
        assertEquals("? sats", l.priceLabel)
    }

    @Test fun `category matches whole words in text`() {
        assertEquals(MarketCategory.OTHER, MarketCategory.classify(emptyList(), "Start your party right"))
        assertEquals(MarketCategory.ART, MarketCategory.classify(emptyList(), "Hand-pulled screen print"))
        assertEquals(MarketCategory.BITCOIN, MarketCategory.classify(emptyList(), "A new hardware wallet"))
        assertEquals(MarketCategory.SHOES, MarketCategory.classify(emptyList(), "Running shoes, size 10"))
        assertEquals(MarketCategory.CLOTHING, MarketCategory.classify(emptyList(), "Cotton hoodie"))
    }

    @Test fun `category matches topic substrings`() {
        assertEquals(MarketCategory.BITCOIN, MarketCategory.classify(listOf("Bitcoin-Hardware"), ""))
        assertEquals(MarketCategory.FOOD_AND_DRINK, MarketCategory.classify(listOf("coffee-beans"), ""))
        assertEquals(MarketCategory.OTHER, MarketCategory.classify(listOf("misc"), ""))
    }
}
