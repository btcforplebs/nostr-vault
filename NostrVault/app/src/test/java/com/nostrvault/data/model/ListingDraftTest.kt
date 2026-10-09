package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Same cases as ListingDraftTests.swift. */
class ListingDraftTest {
    private fun draft(
        category: MarketCategory = MarketCategory.ART,
        price: String = "21,000",
        currency: String = "SATS",
    ) = ListingDraft(
        title = "  Sunset print ", summary = "A3 giclée", description = "Signed.\n",
        price = price, currency = currency, category = category, location = "Ohio",
        imageUrls = listOf("https://blossom.example/a.jpg", "https://blossom.example/b.jpg"),
    )

    @Test fun `tags match NIP-99 and the iPhone`() {
        assertEquals(
            listOf(
                listOf("d", "d1"), listOf("title", "Sunset print"), listOf("summary", "A3 giclée"),
                listOf("published_at", "1790000000"), listOf("price", "21000", "SATS"), listOf("location", "Ohio"),
                listOf("image", "https://blossom.example/a.jpg"), listOf("image", "https://blossom.example/b.jpg"),
                listOf("t", "Art"), listOf("status", "active"),
            ),
            draft().tags(1_790_000_000) { "d1" },
        )
        assertEquals("Signed.", draft().content())
    }

    @Test fun `every category round-trips through the parser`() {
        for (category in MarketCategory.entries) {
            val d = draft(category = category).copy(title = "Item", summary = "", description = "")
            val listing = MarketListing.parse("x", "pk", 30402, d.content(), 0, d.tags(0))!!
            assertEquals(category.name, category, listing.category)
            assertEquals("Item", listing.title)
            assertEquals(2, listing.images.size)
            assertEquals("21000", listing.price)
        }
    }

    @Test fun `incomplete drafts`() {
        assertTrue(draft().isComplete)
        assertFalse(draft(price = "").isComplete)
        assertFalse(draft(price = "free").isComplete)
        assertFalse(draft(price = "-5").isComplete)
        assertFalse(draft().copy(imageUrls = emptyList()).isComplete)
        assertFalse(draft().copy(title = "  ").isComplete)
        assertEquals("45.50", draft(price = "45.50", currency = "USD").normalizedPrice)
    }

    @Test fun `edit keeps address`() {
        assertEquals(listOf("d", "keep-me"), draft().copy(dTag = "keep-me").tags(0).first())
    }
}
