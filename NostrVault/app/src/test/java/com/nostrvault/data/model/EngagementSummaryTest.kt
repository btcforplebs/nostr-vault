package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.Locale

class EngagementSummaryTest {

    private fun reaction(pubkey: String, emoji: String) = ReactionDetail(id = "$pubkey$emoji", pubkey = pubkey, emoji = emoji)

    @Test
    fun `reactions group by emoji, most used first`() {
        val groups = EngagementSummary.groupReactions(
            listOf(
                reaction("a", "🔥"),
                reaction("b", "❤️"),
                reaction("c", "❤️"),
                reaction("d", "🤙"),
                reaction("e", "❤️"),
                reaction("f", "🔥"),
            ),
        )
        assertEquals(
            listOf(
                EngagementSummary.EmojiGroup("❤️", 3),
                EngagementSummary.EmojiGroup("🔥", 2),
                EngagementSummary.EmojiGroup("🤙", 1),
            ),
            groups,
        )
    }

    @Test
    fun `a plus or blank reaction is a heart`() {
        val groups = EngagementSummary.groupReactions(listOf(reaction("a", "+"), reaction("b", ""), reaction("c", "❤️")))
        assertEquals(listOf(EngagementSummary.EmojiGroup("❤️", 3)), groups)
    }

    @Test
    fun `shortcode emoji are left out but composed emoji are kept`() {
        val groups = EngagementSummary.groupReactions(
            listOf(reaction("a", ":pepe:"), reaction("b", "👍🏽"), reaction("c", "🇺🇸")),
        )
        assertEquals(listOf("👍🏽", "🇺🇸"), groups.map { it.emoji })
    }

    @Test
    fun `zap text is count and grouped total`() {
        val previous = Locale.getDefault()
        Locale.setDefault(Locale.US)
        try {
            assertEquals("3 · 2,100", EngagementSummary.zapText(3, 2_100))
            assertEquals("1 · 21", EngagementSummary.zapText(1, 21))
        } finally {
            Locale.setDefault(previous)
        }
    }

    @Test
    fun `thread row groups reactions, totals zaps and counts each reposter once`() {
        val row = EngagementSummary.threadRow(
            EngagementDetails(
                reactions = listOf(reaction("a", "🔥"), reaction("b", "+"), reaction("c", "🔥")),
                zaps = listOf(ZapDetail("z1", "a", 21, ""), ZapDetail("z2", "b", 1_000, "")),
                reposts = listOf(RepostDetail("r1", "a"), RepostDetail("r2", "a"), RepostDetail("r3", "b")),
            ),
            zapsOnly = false,
        )
        assertEquals(
            listOf(EngagementSummary.EmojiGroup("🔥", 2), EngagementSummary.EmojiGroup("❤️", 1)),
            row.emojiGroups,
        )
        assertEquals(2, row.zapCount)
        assertEquals(1_021L, row.zapSats)
        assertEquals(2, row.reposts)
        assertEquals(false, row.isEmpty)
    }

    @Test
    fun `thread row drops reactions in zaps only mode`() {
        val reactionsOnly = EngagementDetails(reactions = listOf(reaction("a", "🔥")))
        val row = EngagementSummary.threadRow(reactionsOnly, zapsOnly = true)
        assertEquals(emptyList<EngagementSummary.EmojiGroup>(), row.emojiGroups)
        assertEquals(true, row.isEmpty)
        assertEquals(false, EngagementSummary.threadRow(reactionsOnly, zapsOnly = false).isEmpty)
    }

    @Test
    fun `an empty note has an empty thread row`() {
        assertEquals(true, EngagementSummary.threadRow(EngagementDetails(), zapsOnly = false).isEmpty)
    }

    @Test
    fun `sats text is the grouped total alone`() {
        val previous = Locale.getDefault()
        Locale.setDefault(Locale.US)
        try {
            assertEquals("2,100", EngagementSummary.satsText(2_100))
            assertEquals("0", EngagementSummary.satsText(0))
        } finally {
            Locale.setDefault(previous)
        }
    }
}
