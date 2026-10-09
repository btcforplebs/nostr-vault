package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The feed's inline article row (iOS ArticleInlineBody): never raw Markdown. */
class ArticleInlinePreviewTest {

    @Test fun `summary wins over the body`() {
        assertEquals("Short take", ArticleMeta.previewText("Short take", "# Heading\n\nBody"))
    }

    @Test fun `without a summary the body is stripped of markdown`() {
        val preview = ArticleMeta.previewText(null, "## Why\n\n---\n\nKeep **your own** [keys](https://x.y).")
        assertEquals("Why Keep your own keys.", preview)
    }

    @Test fun `long bodies are cut with an ellipsis`() {
        val preview = ArticleMeta.previewText(null, "word ".repeat(100), limit = 20)!!
        assertTrue(preview.endsWith("…"))
        assertTrue(preview.length <= 21)
    }

    @Test fun `blank summary and body give nothing`() {
        assertNull(ArticleMeta.previewText("  ", "\n\n"))
    }

    @Test fun `reading time rounds up at 200 words a minute`() {
        assertNull(ArticleMeta.readingTimeMinutes("   "))
        assertEquals(1, ArticleMeta.readingTimeMinutes("one two three"))
        assertEquals(1, ArticleMeta.readingTimeMinutes("w ".repeat(200)))
        assertEquals(2, ArticleMeta.readingTimeMinutes("w ".repeat(201)))
    }
}
