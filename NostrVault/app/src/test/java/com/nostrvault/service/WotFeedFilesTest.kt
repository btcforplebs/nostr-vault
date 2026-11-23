package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

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

    // Tron 2472 low 2: the account's file counts only at its own level and bar.

    private fun built(depth: Int, bar: Int) =
        WotCacheFile.parse("""{"version":5,"depth":$depth,"min_followers":$bar,"pubkeys":{"$me":true,"$other":true}}""", me)!!

    @Test fun `the account file reads its level and bar`() {
        val parsed = built(3, 2)
        assertEquals(3, parsed.depth)
        assertEquals(2, parsed.minFollowers)
    }

    @Test fun `built at the account's own level and bar counts`() {
        assertTrue(WotFeedFiles.builtAt(built(3, 2), com.nostrvault.relay.AccountReach(3, 2)))
    }

    @Test fun `another level or bar falls back to pooled`() {
        assertFalse("another level", WotFeedFiles.builtAt(built(3, 2), com.nostrvault.relay.AccountReach(2, 2)))
        assertFalse("another bar", WotFeedFiles.builtAt(built(3, 2), com.nostrvault.relay.AccountReach(3, 5)))
    }

    @Test fun `the level is held to the relay's range`() {
        assertTrue(WotFeedFiles.builtAt(built(1, 0), com.nostrvault.relay.AccountReach(0, -1)))
    }

    @Test fun `a pooled file without a bar is not held against it`() {
        val pooled = WotCacheFile.parse("""{"pubkeys":{"$me":true,"$other":true}}""", me)!!
        assertTrue(WotFeedFiles.builtAt(pooled, com.nostrvault.relay.AccountReach(3, 9)))
    }

    // Tron 2472 low 3: the pooled file is parsed again only when rewritten.

    @Test fun `the pooled memo parses once per write`() {
        val file = tmp.newFile("wot_cache.json")
        file.writeText("""{"pubkeys":{"$me":true,"$other":true}}""")
        val memo = PooledWotMemo()
        val first = memo.read(file, me)
        assertEquals(setOf(me, other), first?.pubkeys)
        memo.read(file, me)
        assertEquals("same file: no second parse", 1, memo.reads)
        file.writeText("""{"pubkeys":{"$me":true,"$other":true,"${"c".repeat(64)}":true}}""")
        file.setLastModified(file.lastModified() + 5_000)
        assertEquals(3, memo.read(file, me)?.pubkeys?.size)
        assertEquals("a rewrite is parsed", 2, memo.reads)
    }

    @Test fun `the pooled memo does not keep an unreadable read`() {
        val file = tmp.newFile("wot_cache.json")
        file.writeText("{not json")
        val memo = PooledWotMemo()
        assertEquals(null, memo.read(file, me))
        memo.read(file, me)
        assertEquals("an unreadable file is tried again", 2, memo.reads)
        assertEquals(null, memo.read(File(tmp.root, "missing.json"), me))
    }
}
