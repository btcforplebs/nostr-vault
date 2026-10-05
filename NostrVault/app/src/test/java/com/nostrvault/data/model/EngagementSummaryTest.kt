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
}
