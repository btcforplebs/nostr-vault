package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/** Vectors ported from the iOS GatedArticleTests (a real Fanfares article, 2026-10-06). */
class GatedArticleTest {
    private val author = "adc14fa3ad590856dd8b80815d367f7c1e6735ad00fd98a86d002fbe9fb535e1"

    private fun fanfaresTags(ciphertext: String = "AAAA"): List<List<String>> = listOf(
        listOf("d", "d6711eb7-0703-48bb-9fd5-61b96e57283c"),
        listOf("encrypted", "aes-256-gcm", ciphertext, "https://api.fanfares.live/request-key"),
        listOf("price", "42", "SATS"),
        listOf("referral", "8"),
        listOf("zap", author, "wss://fanfares.nostr1.com", "42"),
        listOf("title", "The Christian Man"),
    )

    private fun gated(tags: List<List<String>> = fanfaresTags()) = GatedArticle.from(30023, author, tags)!!

    @Test fun fanfaresArticleIsGated() {
        val g = gated()
        assertEquals(42, g.priceSats)
    }

    @Test fun ordinaryArticleAndNoteKindAreNotGated() {
        assertNull(GatedArticle.from(30023, author, listOf(listOf("d", "x"), listOf("title", "Free"))))
        assertNull(GatedArticle.from(1, author, fanfaresTags()))
    }

    @Test fun missingKeyUrlPriceFiatOrUnknownCipherIsNotActionable() {
        val noUrl = fanfaresTags().toMutableList().also { it[1] = listOf("encrypted", "aes-256-gcm", "AAAA") }
        assertNull(GatedArticle.from(30023, author, noUrl))
        assertNull(GatedArticle.from(30023, author, fanfaresTags().filter { it[0] != "price" }))
        val fiat = fanfaresTags().toMutableList().also { it[2] = listOf("price", "5", "USD") }
        assertNull(GatedArticle.from(30023, author, fiat))
        val cipher = fanfaresTags().toMutableList().also { it[1] = listOf("encrypted", "chacha20", "AAAA", "https://api.fanfares.live/request-key") }
        assertNull(GatedArticle.from(30023, author, cipher))
        val http = fanfaresTags().toMutableList().also { it[1] = listOf("encrypted", "aes-256-gcm", "AAAA", "http://keys.example.com/k") }
        assertNull(GatedArticle.from(30023, author, http))
    }

    // Encrypted by WebCrypto (Node), the API Fanfares' site uses: IV || ct || tag.
    private val blob = "AQIDBAUGBwgJCgsMWVJSyIdkwGGGkd2kTIZsMgf2yoQI++wXRPfUyTlbSWgkrDfVohPZs+M3pLRXdVxSVrYS98ZTHe8/9vfNgHI8mpNeo5hR6fphTQME+3RawQ=="
    private val key = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

    @Test fun decryptsWebCryptoAesGcm() {
        val g = gated(fanfaresTags(blob))
        assertEquals("# Whose life is this?\n\nThe full article — with ünïcode ⚡.", g.decrypt(key))
        // The server's body may carry a trailing newline, and any case.
        assertNotNull(g.decrypt(key.uppercase() + "\n"))
    }

    @Test fun wrongOrMalformedKeyDecryptsNothing() {
        val g = gated(fanfaresTags(blob))
        assertNull(g.decrypt("0".repeat(64)))
        assertNull(g.decrypt("Payment not verified"))
        assertNull(g.decrypt(key.dropLast(2)))
    }

    @Test fun teaserDropsTheCallToActionAndLink() {
        val content = "Christian manhood starts with one question: whose life is this?\n\n⚡ Zap 42 sats to unlock the full article on\nhttps://fanfares.io/naddr/naddr1xyz"
        assertEquals("Christian manhood starts with one question: whose life is this?", GatedArticleTeaser.strip(content))
        assertEquals("Just a teaser.", GatedArticleTeaser.strip("Just a teaser."))
    }
}
