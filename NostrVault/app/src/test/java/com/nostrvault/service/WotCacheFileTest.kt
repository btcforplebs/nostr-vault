package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** wot_cache.json read once for both the graph and its vouches (Moto check 11-01 #1). */
class WotCacheFileTest {
    private val owner = "a".repeat(64)
    private val alice = "b".repeat(64)
    private val bob = "c".repeat(64)

    @Test fun `one read gives the graph and the vouches`() {
        val content = """{"pubkeys":{"$owner":true,"$alice":true,"$bob":true},"follows":["$alice"],"vouches":{"$bob":12},"timestamp":1}"""
        val parsed = WotCacheFile.parse(content, owner)
        assertEquals(setOf(owner, alice, bob), parsed?.pubkeys)
        assertEquals(mapOf(bob to 12), parsed?.vouches)
    }

    @Test fun `a cache without vouches has a graph and null vouches`() {
        val parsed = WotCacheFile.read("""  {"pubkeys":{"$owner":true,"$alice":true}}""".byteInputStream(), owner)
        assertEquals(setOf(owner, alice), parsed?.pubkeys)
        assertNull(parsed?.vouches)
    }

    @Test fun `owner-only graph is empty, unreadable is null`() {
        assertEquals(emptySet<String>(), WotCacheFile.parse("""{"pubkeys":{"$owner":true}}""", owner)?.pubkeys)
        assertNull(WotCacheFile.parse("not json", owner))
        assertNull(WotCacheFile.parse("""{"timestamp":1}""", owner))
        assertNull(WotCacheFile.parse("", owner))
        assertNull(WotCacheFile.parse("""{"pubkeys":{"$alice":true""", owner))
    }

    @Test fun `bare array still reads`() {
        assertEquals(setOf(alice), WotCacheFile.parse(""" ["$alice"]""", owner)?.pubkeys)
    }
}
