package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** The feed reads the open account's wot_cache_<hex>.json, the pooled file only while it is missing. */
class WotFeedFilesTest {
    @get:Rule val tmp = TemporaryFolder()
    private val me = "a".repeat(64)
    private val other = "b".repeat(64)

    @Test fun `the open account's own pair when its cache exists`() {
        val dir = tmp.root
        tmp.newFile("wot_cache.json")
        tmp.newFile("wot_cache_$me.json")
        val files = WotFeedFiles.forAccount(dir, me)
        assertTrue(files.perAccount)
        assertEquals("wot_cache_$me.json", files.cache.name)
        assertEquals("wot_links_$me.json", files.links.name)
    }

    @Test fun `upper-case hex finds the relay's lower-case file`() {
        tmp.newFile("wot_cache_$me.json")
        val files = WotFeedFiles.forAccount(tmp.root, me.uppercase())
        assertTrue(files.perAccount)
        assertEquals("wot_cache_$me.json", files.cache.name)
    }

    @Test fun `falls back to the pooled pair while the account's file is missing`() {
        tmp.newFile("wot_cache.json")
        tmp.newFile("wot_cache_$other.json") // another account's file is never read for me
        val files = WotFeedFiles.forAccount(tmp.root, me)
        assertFalse(files.perAccount)
        assertEquals("wot_cache.json", files.cache.name)
        assertEquals("wot_links.json", files.links.name)
    }

    @Test fun `no open account or a bad key reads the pooled pair`() {
        tmp.newFile("wot_cache_.json")
        assertFalse(WotFeedFiles.forAccount(tmp.root, "").perAccount)
        assertFalse(WotFeedFiles.forAccount(tmp.root, "../x").perAccount)
    }

    @Test fun `a directory named like the cache is not a cache`() {
        tmp.newFolder("wot_cache_$me.json")
        assertFalse(WotFeedFiles.forAccount(tmp.root, me).perAccount)
    }

    @Test fun `writes that reload the feed web`() {
        assertTrue(WotFeedFiles.isFeedFile("wot_cache.json", me))
        assertTrue(WotFeedFiles.isFeedFile("wot_links.json", me))
        assertTrue(WotFeedFiles.isFeedFile("wot_cache_$me.json", me))
        assertTrue(WotFeedFiles.isFeedFile("wot_links_$me.json", me))
        assertFalse(WotFeedFiles.isFeedFile("wot_cache_$other.json", me))
        assertFalse(WotFeedFiles.isFeedFile("wot_cache_$me.json.tmp", me))
        assertFalse(WotFeedFiles.isFeedFile(null, me))
    }

    @Test fun `the account file reads as the pooled shape`() {
        // haven-go accountCache: version/depth/min_followers/follows/pubkeys/vouches/muted_follows.
        val content = """{"version":5,"depth":3,"min_followers":3,"timestamp":1,"follows":["$other"],"pubkeys":{"$me":true,"$other":true},"vouches":{"$other":4},"muted_follows":[]}"""
        val parsed = WotCacheFile.parse(content, me)
        assertEquals(setOf(me, other), parsed?.pubkeys)
        assertEquals(3, parsed?.depth)
        assertEquals(mapOf(other to 4), parsed?.vouches)
    }
}
