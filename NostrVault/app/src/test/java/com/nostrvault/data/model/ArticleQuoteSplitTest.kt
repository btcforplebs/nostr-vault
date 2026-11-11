package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Logen 2026-11-11: an nevent, note or naddr written inside an article body
 * draws as a quote card, not as a bare `nostr:nevent1…`. iOS ArticleQuoteSplitTests.
 */
class ArticleQuoteSplitTest {
    private val eventHex = "a".repeat(64)
    private val authorHex = "c".repeat(64)

    /** Decodes by name alone, so the tests need no bech32 and no native library. */
    private val decoder = object : QuoteRef.Decoder {
        override fun noteToHex(note1: String) = if (note1 == "note1aaa") eventHex else null
        override fun neventToHex(nevent1: String) = if (nevent1 == "nevent1aaa") eventHex else null
        override fun naddrToCoordinate(naddr1: String) =
            if (naddr1 == "naddr1ccc") QuoteRef.Coordinate(30023, authorHex, "2xv8JTwpLs0S0FDIqo0XL") else null
    }

    @Test fun `a block that is only a quote becomes a card`() {
        assertEquals("" to listOf(eventHex), QuoteRef.articleQuoteSplit("nostr:nevent1aaa", decoder))
    }

    @Test fun `text around the quote stays and the card follows`() {
        assertEquals("Read this: it is good." to listOf(eventHex),
            QuoteRef.articleQuoteSplit("Read this: nostr:note1aaa it is good.", decoder))
    }

    @Test fun `a markdown link to a quote keeps its label`() {
        val split = QuoteRef.articleQuoteSplit("See [the recap](nostr:naddr1ccc).", decoder)
        assertEquals("See the recap.", split?.first)
        assertEquals(listOf("naddr:30023:$authorHex:2xv8JTwpLs0S0FDIqo0XL"), split?.second)
    }

    @Test fun `a block with no quote is left alone`() {
        assertNull(QuoteRef.articleQuoteSplit("Plain words and https://njump.me/nevent1aaa", decoder))
    }

    /** iOS and web leave code alone; a reference in a fence is code, not a quote. */
    @Test fun `a code fence is left alone`() {
        assertNull(QuoteRef.articleQuoteSplit("```\nnostr:nevent1aaa\n```", decoder))
        assertNull(QuoteRef.articleQuoteSplit("~~~kotlin\nval x = \"nostr:note1aaa\"\n~~~", decoder))
    }
}
