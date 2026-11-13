package com.nostrvault.service.emoji

import com.nostrvault.fips.EmojiNote
import com.nostrvault.service.CustomEmoji
import com.nostrvault.service.EmojiListRepository
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Tron's PR 2024 review: zip matches never give one file to two links, the picker fetches 20 sets, the folder is listed rarely. */
class EmojiReviewFixesTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private val pk = "b".repeat(64)
    private val cats = "30030:$pk:cats"
    private val birds = "30030:$pk:birds"
    private val sha = "1".repeat(64)
    private val other = "2".repeat(64)

    private fun set(address: String, vararg e: Pair<String, String>) =
        EmojiListRepository.EmojiSet(address, address.substringAfterLast(':'), e.map { CustomEmoji(it.first, it.second, address) }, pk)

    @Test
    fun `a name used by two image links matches nothing`() {
        val sets = listOf(set(cats, "smile" to "https://a.example/smile.png"), set(birds, "smile" to "https://b.example/smile.png"))
        assertNull(EmojiCopyRules.zipMatch("pack/smile.png", "f".repeat(64), sets))
    }

    @Test
    fun `the same link in two sets is one link, so its name still matches`() {
        val sets = listOf(set(cats, "smile" to "https://a.example/smile.png"), set(birds, "smile" to "https://a.example/smile.png"))
        val m = EmojiCopyRules.zipMatch("smile.png", "f".repeat(64), sets)!!
        assertEquals(listOf(cats, birds), m.sets)
    }

    @Test
    fun `a name match never overrides the hash its link carries`() {
        val url = "https://cdn.example.com/$other.png"
        val sets = listOf(set(cats, "smile" to url))
        assertNull("bytes hash to something else", EmojiCopyRules.zipMatch("smile.png", sha, sets))
        assertNotNull("bytes hash right", EmojiCopyRules.zipMatch("smile.png", other, sets))
    }

    @Test
    fun `a hash match names every link it fills, and a hashed link does not make a name ambiguous`() {
        val hashed = "https://cdn.example.com/$sha.png"
        val sets = listOf(
            set(cats, "blobcat" to hashed, "smile" to "https://a.example/smile.png"),
            set(birds, "blobcat2" to "https://mirror.example/$sha.webp", "smile" to "https://cdn.example.com/$other.png"),
        )
        val m = EmojiCopyRules.zipMatch("smile.png", sha, sets)!!
        assertEquals(setOf(hashed, "https://mirror.example/$sha.webp", "https://a.example/smile.png"), m.codes.map { it[1] }.toSet())
    }

    @Test
    fun `a narrow refresh keeps the sets past 20 as the page last fetched them`() {
        val addresses = (0 until 120).map { "30030:$pk:s$it" }
        val kept = addresses.map { set(it) }
        val beyond = EmojiListRepository.keptBeyond(addresses, EmojiListRepository.MAX_SETS_PICKER, kept)
        assertEquals(addresses.subList(20, 100), beyond.map { it.address })
        assertEquals(emptyList<EmojiListRepository.EmojiSet>(), EmojiListRepository.keptBeyond(addresses, EmojiListRepository.MAX_SETS_PAGE, kept))
    }

    @Test
    fun `the vault folder is listed again only after a store or when a copy is missing for a while`() {
        val dir = tmp.newFolder()
        val url = "https://a.example/a.png"
        val note = listOf(EmojiNote("n1", 1, sha, "image/png", 1, listOf(listOf("a", url)), emptyList()))
        EmojiLocalCopies.update(emptyList(), note, dir, relist = true, now = 1_000)
        assertNull(EmojiLocalCopies.byUrl.value[url])
        java.io.File(dir, "$sha.png").writeText("x")
        EmojiLocalCopies.update(emptyList(), note, dir, relist = false, now = 2_000)
        assertNull("listed 1 s ago: not again", EmojiLocalCopies.byUrl.value[url])
        EmojiLocalCopies.update(emptyList(), note, dir, relist = false, now = 40_000)
        assertNotNull("missing for over 30 s: listed again", EmojiLocalCopies.byUrl.value[url])
        java.io.File(dir, "$other.png").writeText("y")
        val two = note + EmojiNote("n2", 1, other, "image/png", 1, listOf(listOf("b", "https://b")), emptyList())
        EmojiLocalCopies.update(emptyList(), two, dir, relist = true, now = 41_000)
        assertNotNull("after a store", EmojiLocalCopies.byUrl.value["https://b"])
    }
}
