package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** What a compact row shows instead of the body. iOS: `FeedNote.condensedTitle`. */
class CondensedTitleTest {
    private fun note(kind: Int, content: String, tags: List<List<String>> = emptyList()) =
        FeedNote.fromEvent(id = "a".repeat(64), pubkey = "b".repeat(64), content = content, tags = tags,
            createdAt = 1_700_000_000L, kind = kind)

    @Test fun `an article shows its title`() {
        assertEquals("On Vaults", note(ArticleMeta.KIND, "# Heading\n\nBody", listOf(listOf("title", "On Vaults"))).condensedTitle)
    }

    @Test fun `an untitled article falls back to its first line`() {
        assertEquals("Heading", note(ArticleMeta.KIND, "# Heading\n\nBody").condensedTitle)
    }

    @Test fun `a plain note has none`() {
        assertNull(note(1, "hello").condensedTitle)
    }
}
