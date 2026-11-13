package com.nostrvault.service.emoji

import com.nostrvault.service.ListShrinkRule
import com.nostrvault.service.ListVersion
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Your old sets in Find emoji sets (Logen 2026-11-13): which own sets show, and which copy Add back brings. */
class OwnEmojiSetsTest {
    private val me = "a".repeat(64)
    private val them = "b".repeat(64)
    private var n = 0

    private fun set(d: String, emoji: Int, at: Long, author: String = me, title: String? = null): ListVersion {
        val tags = mutableListOf(listOf("d", d))
        title?.let { tags += listOf("title", it) }
        repeat(emoji) { tags += listOf("emoji", "e$it", "https://cdn.example.com/$d$it.png") }
        n++
        return ListVersion("%064x".format(n), author, 30030, at, tags, "")
    }

    private fun addr(d: String) = "30030:$me:$d"

    @Test
    fun `an own set not in the emoji list shows with its newest copy`() {
        val old = set("cats", 3, at = 1)
        val newer = set("cats", 4, at = 2, title = "Cats")
        val got = OwnEmojiSets.pick(listOf(old, newer, newer), me, listed = emptySet())
        assertEquals(1, got.size)
        assertEquals(addr("cats"), got[0].address)
        assertEquals(newer.id, got[0].version.id)
        assertEquals("Cats", got[0].set.title)
        assertFalse(got[0].restore)
        assertFalse(got[0].listed)
    }

    @Test
    fun `a listed set that is fine does not show`() {
        assertTrue(OwnEmojiSets.pick(listOf(set("cats", 5, at = 1)), me, setOf(addr("cats"))).isEmpty())
    }

    @Test
    fun `a listed set whose newest copy was emptied comes back from the fullest older copy`() {
        val small = set("cats", 2, at = 1)
        val full = set("cats", 6, at = 2)
        val emptied = set("cats", 0, at = 3)
        val got = OwnEmojiSets.pick(listOf(emptied, small, full), me, setOf(addr("cats"))).single()
        assertTrue(got.restore)
        assertTrue(got.listed)
        assertEquals(full.id, got.version.id)
        assertEquals(emptied.id, got.newest.id)
        assertEquals(0, got.newestCount)
        assertEquals(6, got.set.emojis.size)
    }

    @Test
    fun `a big set cut under half is a wipe, a small trim is an edit`() {
        val big = set("big", 12, at = 1)
        val cut = set("big", 2, at = 2)
        assertTrue(OwnEmojiSets.pick(listOf(big, cut), me, setOf(addr("big"))).single().restore)
        val five = set("five", 8, at = 1)
        val trimmed = set("five", 5, at = 2)
        assertTrue(OwnEmojiSets.pick(listOf(five, trimmed), me, setOf(addr("five"))).isEmpty())
        // The same trim not in the list shows the newest copy as it is.
        assertEquals(trimmed.id, OwnEmojiSets.pick(listOf(five, trimmed), me, emptySet()).single().version.id)
    }

    @Test
    fun `other people's sets, other kinds and sets that never had an emoji are left out`() {
        val versions = listOf(
            set("theirs", 4, at = 1, author = them),
            set("empty", 0, at = 1),
            set("empty", 0, at = 2),
            set("cats", 3, at = 1).copy(kind = 30003),
        )
        assertTrue(OwnEmojiSets.pick(versions, me, emptySet()).isEmpty())
    }

    @Test
    fun `newest first`() {
        val got = OwnEmojiSets.pick(listOf(set("a", 1, at = 5), set("b", 1, at = 9), set("c", 1, at = 7)), me, emptySet())
        assertEquals(listOf(addr("b"), addr("c"), addr("a")), got.map { it.address })
    }

    @Test
    fun `emoji sets are kept in list history like the emoji list`() {
        assertTrue(ListShrinkRule.isProtected(30030))
        assertEquals("emoji set", ListShrinkRule.name(30030))
    }
}
