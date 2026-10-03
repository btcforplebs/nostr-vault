package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** wot_cache.json as haven-go's wotCache writes it (pkg/wot/simple_in_memory.go). */
class WotCacheParseTest {
    private val owner = "a".repeat(64)
    private val alice = "b".repeat(64)
    private val bob = "c".repeat(64)

    @Test fun `reads the relay's object format`() {
        val content = """{"pubkeys":{"$owner":true,"$alice":true,"$bob":true},"timestamp":1791060000}"""
        assertEquals(setOf(owner, alice, bob), FeedFilterEngine.parseWotCache(content, owner))
    }

    @Test fun `owner-only graph carries no trust and comes back empty`() {
        val content = """{"pubkeys":{"$owner":true},"timestamp":1}"""
        assertEquals(emptySet<String>(), FeedFilterEngine.parseWotCache(content, owner))
    }

    @Test fun `unreadable content returns null so the caller keeps its graph`() {
        assertNull(FeedFilterEngine.parseWotCache("not json", owner))
        assertNull(FeedFilterEngine.parseWotCache("""{"timestamp":1}""", owner))
    }

    @Test fun `a bare array is still accepted`() {
        assertEquals(setOf(alice), FeedFilterEngine.parseWotCache("""["$alice"]""", owner))
    }
}
