package com.nostrvault.service.emoji

import com.nostrvault.fips.EmojiNote
import com.nostrvault.service.CustomEmoji
import com.nostrvault.service.EmojiListRepository
import com.nostrvault.service.NostrEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class EmojiCopyRulesTest {
    private val pk = "b".repeat(64)
    private val cats = "30030:$pk:cats"
    private val birds = "30030:$pk:birds"
    private val sha = "1".repeat(64)
    private val shaUrl = "https://cdn.example.com/$sha.png"

    private fun set(address: String, vararg e: Pair<String, String>) =
        EmojiListRepository.EmojiSet(address, address.substringAfterLast(':'), e.map { CustomEmoji(it.first, it.second, address) }, pk)

    @Test
    fun `wanted is one entry per image with every code and set using it`() {
        val w = EmojiCopyRules.wanted(listOf(
            set(cats, "blobcat" to shaUrl, "bad code!" to "https://x.example/y.png"),
            set(birds, "blobcat2" to shaUrl, "parrot" to "https://x.example/p.gif"),
        ))
        assertEquals(listOf(shaUrl, "https://x.example/p.gif"), w.map { it.url })
        assertEquals(listOf(listOf("blobcat", shaUrl), listOf("blobcat2", shaUrl)), w[0].codes)
        assertEquals(listOf(cats, birds), w[0].sets)
    }

    @Test
    fun `a dead link is looked for by its hash, own servers first, never its own host`() {
        assertEquals(sha, EmojiCopyRules.hashInUrl(shaUrl))
        assertNull(EmojiCopyRules.hashInUrl("https://x.example/party.gif"))
        val urls = EmojiCopyRules.searchUrls(shaUrl, listOf("https://my.server/", "http://plain.example", "https://cdn.example.com"))
        assertEquals("https://my.server/$sha", urls.first())
        assertTrue(urls.none { it.startsWith("https://cdn.example.com") || it.startsWith("http://") })
        assertTrue(urls.containsAll(EmojiCopyRules.SEARCH_SERVERS.map { "$it/$sha" }))
        assertEquals(emptyList<String>(), EmojiCopyRules.searchUrls("https://x.example/party.gif", listOf("https://my.server")))
    }

    @Test
    fun `only images up to 2 MB are saved, and a run stops at its caps`() {
        assertNull(EmojiCopyRules.refusal("image/png", 10))
        assertNull(EmojiCopyRules.refusal("image/webp; charset=binary", EmojiCopyRules.MAX_IMAGE_BYTES))
        assertEquals(EmojiCopyRules.Skip.TOO_BIG, EmojiCopyRules.refusal("image/gif", EmojiCopyRules.MAX_IMAGE_BYTES + 1))
        assertEquals(EmojiCopyRules.Skip.NOT_IMAGE, EmojiCopyRules.refusal("image/svg+xml", 10))
        assertEquals(EmojiCopyRules.Skip.NOT_IMAGE, EmojiCopyRules.refusal("text/html", 10))
        assertTrue(EmojiCopyRules.Tally(saved = EmojiCopyRules.MAX_FILES).capReached(1))
        assertTrue(EmojiCopyRules.Tally(bytes = EmojiCopyRules.MAX_TOTAL_BYTES).capReached(1))
        assertFalse(EmojiCopyRules.Tally(saved = 1, bytes = 10).capReached(10))
        assertEquals("Saved 3 · 2 dead · 1 too big", EmojiCopyRules.Tally(saved = 3, dead = 2, tooBig = 1).line())
    }

    @Test
    fun `a zip file matches by shortcode or by hash, else it is skipped`() {
        val sets = listOf(set(cats, "blobcat" to shaUrl, "party" to "https://x.example/party.gif"))
        assertEquals("https://x.example/party.gif", EmojiCopyRules.zipMatch("pack/party.gif", "f".repeat(64), sets)?.url)
        val byHash = EmojiCopyRules.zipMatch("whatever.png", sha, sets)!!
        assertEquals(listOf(listOf("blobcat", shaUrl)), byHash.codes)
        assertEquals(listOf(cats), byHash.sets)
        assertNull(EmojiCopyRules.zipMatch("loose.png", "f".repeat(64), sets))
        assertTrue(EmojiCopyRules.zipEntryLooksLikeImage("pack/a.PNG"))
        assertFalse(EmojiCopyRules.zipEntryLooksLikeImage("../a.png"))
        assertFalse(EmojiCopyRules.zipEntryLooksLikeImage("__MACOSX/._a.png"))
        assertFalse(EmojiCopyRules.zipEntryLooksLikeImage("a.svg"))
    }

    @Test
    fun `adding or removing a set changes one a tag and keeps every other tag`() {
        val current = listOf(listOf("emoji", "loose", "https://x.example/l.png"), listOf("a", birds), listOf("client", "other-app"))
        assertEquals(current + listOf(listOf("a", cats)), EmojiCopyRules.listTags(current, cats, add = true))
        assertNull("already there", EmojiCopyRules.listTags(current, birds, add = true))
        assertEquals(listOf(current[0], current[2]), EmojiCopyRules.listTags(current, birds, add = false))
        assertNull("not there", EmojiCopyRules.listTags(current, cats, add = false))
        assertNull("not a set address", EmojiCopyRules.listTags(current, "10030:$pk:", add = true))
    }

    @Test
    fun `the page lists the list's sets, then sets only saved copies name, and marks dead links`() {
        val sets = listOf(set(cats, "blobcat" to shaUrl, "party" to "https://x.example/party.gif", "gone" to "https://x.example/gone.png"))
        val saved = listOf(EmojiVaultStore.Saved(sha, "image/png", 9, listOf(listOf("blobcat", shaUrl)), listOf(cats)))
        val note = EmojiNote("n1", 1, "2".repeat(64), "image/gif", 9, listOf(listOf("owl", "https://x.example/owl.gif")), listOf(birds))
        val blocks = EmojiVaultPage.blocks(sets, saved, listOf(note), setOf("https://x.example/gone.png"))
        assertEquals(listOf(cats, birds), blocks.map { it.address })
        assertEquals(1, blocks[0].savedCount)
        assertTrue(blocks[0].tiles.single { it.code == "gone" }.dead)
        assertFalse(blocks[0].tiles.single { it.code == "party" }.dead)
        assertFalse(blocks[1].listed)
        assertEquals("birds", blocks[1].title)
    }

    @Test
    fun `Media leaves out hidden hashes only`() {
        assertEquals(listOf("a", "c"), EmojiMediaRule.shown(listOf("a", "B", "c"), setOf("b")) { it })
    }

    @Test
    fun `browse keeps the newest event per set address`() {
        fun ev(id: String, d: String, at: Long) = NostrEvent(id, pk, at, 30030, listOf(listOf("d", d)), "", "s")
        val picked = EmojiSetPick.newestPerAddress(listOf(ev("1", "cats", 10), ev("2", "cats", 20), ev("3", "birds", 15),
            NostrEvent("4", pk, 30, 30030, emptyList(), "", "s")))
        assertEquals(listOf("2", "3"), picked.map { it.id })
        assertEquals(cats, EmojiSetPick.address(picked[0]))
    }

    @Test
    fun `an emoji drawn anywhere uses the vault copy when one exists`() {
        val f = File("x")
        val map = EmojiLocalCopies.urlMap(listOf(sha to listOf(listOf("blobcat", shaUrl)), "3".repeat(64) to listOf(listOf("gone", "https://g")))) {
            if (it == sha) f else null
        }
        assertEquals(mapOf(shaUrl to f), map)
    }
}
