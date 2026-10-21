package com.nostrvault.ui.screens.feed

import com.nostrvault.data.model.FeedProfile
import org.junit.Assert.assertEquals
import org.junit.Test

class ArticleCardTest {
    @Test
    fun `topics are the t tags lowercased, first three`() {
        val tags = listOf(
            listOf("d", "x"), listOf("t", "Bitcoin"), listOf("title", "T"), listOf("t", "nostr"),
            listOf("t", ""), listOf("t", "Lightning"), listOf("t", "fourth"),
        )
        assertEquals(listOf("bitcoin", "nostr", "lightning"), articleTopics(tags))
    }

    @Test
    fun `no t tags gives no chips`() {
        assertEquals(emptyList<String>(), articleTopics(listOf(listOf("d", "x"), listOf("t"))))
    }

    @Test
    fun `author falls back to npub and the last six of the key`() {
        val key = "a".repeat(58) + "123456"
        assertEquals("npub…123456", articleAuthorName(null, key))
        assertEquals("Alice", articleAuthorName(FeedProfile(pubkey = key, displayName = "Alice"), key))
    }
}
