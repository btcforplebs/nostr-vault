package com.nostrvault.service

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Marketplace Global asks relays for trusted sellers by name (iOS `trustScopedFilters`). */
class MarketplaceTrustFiltersTest {

    private val kinds = listOf(30402, 30017, 30018)

    private fun parse(filters: List<String>): List<JsonObject> = filters.map { Json.parseToJsonElement(it).jsonObject }
    private fun authors(f: JsonObject): List<String>? = (f["authors"] as? JsonArray)?.map { it.toString().trim('"') }

    @Test fun `everyone asks once, open`() {
        val f = parse(MarketplaceFeedService.filters(kinds, null, null))
        assertEquals(1, f.size)
        assertFalse("authors" in f[0])
        assertEquals(3, f[0]["kinds"]!!.jsonArray.size)
    }

    @Test fun `web of trust names trusted authors, then asks open`() {
        val trust = setOf("b".repeat(64), "a".repeat(64))
        val f = parse(MarketplaceFeedService.filters(kinds, null, trust))
        assertEquals(2, f.size)
        assertEquals(listOf("a".repeat(64), "b".repeat(64)), authors(f[0]))
        assertFalse("authors" in f[1])
    }

    @Test fun `trusted authors are capped`() {
        val trust = (0 until 700).map { it.toString().padStart(64, '0') }.toSet()
        val f = parse(MarketplaceFeedService.filters(kinds, null, trust))
        assertEquals(MarketplaceFeedService.AUTHORS_CAP, authors(f[0])!!.size)
    }

    @Test fun `empty trust graph asks open`() {
        val f = parse(MarketplaceFeedService.filters(kinds, null, emptySet()))
        assertEquals(1, f.size)
        assertFalse("authors" in f[0])
    }

    @Test fun `following asks only for follows`() {
        val follows = listOf("c".repeat(64))
        val f = parse(MarketplaceFeedService.filters(kinds, follows, null))
        assertEquals(1, f.size)
        assertEquals(follows, authors(f[0]))
        assertTrue(f[0].toString().contains("\"limit\":200"))
    }

    /** Conduit's marketplace relay is asked (Logen, 2026-10-17), once. */
    @Test
    fun `marketplace asks conduit's relay`() {
        assertTrue("wss://relay.conduit.market" in MarketplaceFeedService.RELAYS)
        assertEquals(MarketplaceFeedService.RELAYS.distinct(), MarketplaceFeedService.RELAYS)
    }
}
