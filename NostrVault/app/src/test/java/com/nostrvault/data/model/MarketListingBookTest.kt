package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Same cases as the MarketListingBook tests in MarketListingTests.swift. */
class MarketListingBookTest {
    private fun tags(status: String, d: String = "mug") = listOf(
        listOf("d", d), listOf("title", "Mug"), listOf("image", "https://x.example/m.jpg"),
        listOf("price", "10", "USD"), listOf("status", status),
    )

    @Test fun `sold re-publish hides the older active listing`() {
        val book = MarketListingBook()
        assertTrue(book.insert("a", "pk", 30402, "", 100, tags("active")))
        assertEquals(listOf("a"), book.listings.map { it.id })
        assertTrue(book.insert("b", "pk", 30402, "", 200, tags("sold")))
        assertTrue(book.listings.isEmpty())
    }

    @Test fun `older active arriving after sold stays hidden`() {
        // Relays answer in any order: the sold version can land first.
        val book = MarketListingBook()
        assertFalse(book.insert("b", "pk", 30402, "", 200, tags("sold")))
        assertFalse(book.insert("a", "pk", 30402, "", 100, tags("active")))
        assertTrue(book.listings.isEmpty())
    }

    @Test fun `relisting after sold shows again`() {
        val book = MarketListingBook()
        book.insert("b", "pk", 30402, "", 200, tags("sold"))
        assertTrue(book.insert("c", "pk", 30402, "", 300, tags("active")))
        assertEquals(listOf("c"), book.listings.map { it.id })
    }

    @Test fun `addresses are independent and newest first`() {
        val book = MarketListingBook()
        book.insert("a", "pk", 30402, "", 100, tags("active", d = "one"))
        book.insert("b", "pk", 30402, "", 200, tags("active", d = "two"))
        book.insert("c", "pk", 30402, "", 300, tags("sold", d = "one"))
        assertEquals(listOf("b"), book.listings.map { it.id })
        assertFalse(book.insert("b", "pk", 30402, "", 200, tags("active", d = "two")))
    }
}
