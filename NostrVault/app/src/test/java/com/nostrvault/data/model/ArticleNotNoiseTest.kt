package com.nostrvault.data.model

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The feed's spam rule judged article markdown. Nomishka's Weekly Nostr Recap
 * 101 article (2026-11-11, kind 30023) has 25 blank lines in a row, and the
 * repeated-character rule dropped it. iOS FeedLookupRoutingTests.
 */
class ArticleNotNoiseTest {
    private val article = "# Weekly Nostr Recap 101\n\nIntro paragraph." +
        "\n".repeat(25) + "## Section two\n\nMore text, and a rule:\n\n-----\n\nEnd."

    private fun event(kind: Int, content: String) =
        FeedNote.fromEvent("a".repeat(64), "b".repeat(64), content, listOf(listOf("d", "2xv8JTwpLs0S0FDIqo0XL")), 1_700_000_000L, kind)

    @Test fun `an article is never noise by its text`() {
        assertFalse(event(30023, article).isNoise)
        assertFalse(event(30024, article).isNoise)
    }

    @Test fun `a short note with the same text is still noise`() {
        assertTrue(event(1, article).isNoise)
        assertFalse(event(1, "gm, a normal note").isNoise)
    }
}
