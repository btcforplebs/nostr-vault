package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors HavenApp/MediaLogicTests/Tests/MediaLogicTests/ArticleHighlightTests.swift. */
class ArticleHighlightTest {
    private val articleId = "a".repeat(64)
    private val author = "b".repeat(64)
    private val coordinate = "30023:$author:my-post"
    private val now = 1_800_000_000L

    private fun highlight(
        tags: List<List<String>>,
        content: String = "A passage",
        kind: Int = ArticleEngagement.HIGHLIGHT_KIND,
        createdAt: Long = now - 60,
        id: String = "c".repeat(64),
    ) = ArticleHighlight.from(kind, id, "d".repeat(64), content, createdAt, tags, articleId, coordinate, now)

    @Test fun filtersAskByAddressAndById() {
        val filters = ArticleEngagement.highlightFilters(articleId, coordinate)
        assertEquals(2, filters.size)
        assertTrue(filters[0].contains("\"#a\":[\"$coordinate\"]"))
        assertTrue(filters[1].contains("\"#e\":[\"$articleId\"]"))
        assertTrue(filters.all { it.contains("\"kinds\":[9802]") })
        assertEquals(1, ArticleEngagement.highlightFilters(articleId, null).size)
    }

    @Test fun aHighlightByAddressOrVersionCounts() {
        assertNotNull(highlight(listOf(listOf("a", coordinate))))
        assertNotNull(highlight(listOf(listOf("e", articleId))))
    }

    @Test fun aHighlightOfSomethingElseIsRefused() {
        assertNull(highlight(listOf(listOf("e", "f".repeat(64)))))
    }

    @Test fun wrongKindOrEmptyPassageIsRefused() {
        assertNull(highlight(listOf(listOf("e", articleId)), kind = 1))
        assertNull(highlight(listOf(listOf("e", articleId)), content = "   "))
    }

    @Test fun anOverlongPassageIsRefused() {
        assertNull(highlight(listOf(listOf("e", articleId)), content = "x".repeat(ArticleEngagement.MAX_PASSAGE_LENGTH + 1)))
    }

    @Test fun aHighlightDatedInTheFutureIsRefused() {
        assertNull(highlight(listOf(listOf("e", articleId)), createdAt = now + 3_600))
        assertNotNull(highlight(listOf(listOf("e", articleId)), createdAt = now + 60))
    }

    @Test fun commentTagIsKept() {
        val h = highlight(listOf(listOf("e", articleId), listOf("comment", " So true ")))
        assertEquals("So true", h?.comment)
        assertNull(highlight(listOf(listOf("e", articleId), listOf("comment", "  ")))?.comment)
    }

    @Test fun fourHundredHighlightsShowTheNewestFifty() {
        val many = (0 until 400).map { i ->
            highlight(listOf(listOf("e", articleId)), createdAt = now - 10_000 + i, id = i.toString().padStart(64, '0'))!!
        }
        val shown = ArticleEngagement.shown(many)
        assertEquals(ArticleEngagement.MAX_SHOWN_HIGHLIGHTS, shown.size)
        assertEquals(now - 10_000 + 399, shown.first().createdAt)
    }

    @Test fun placementFindsTheParagraphDespiteCaseWrappingAndMarkup() {
        val blocks = ArticleEngagement.blocks("# Title\n\nFirst **para**graph here.\n\nSecond one\nwraps onto a line.")
        val h = highlight(listOf(listOf("e", articleId)), content = "second ONE wraps")!!
        val missing = highlight(listOf(listOf("e", articleId)), content = "not in the article", id = "e".repeat(64))!!
        val placed = ArticleEngagement.place(listOf(h, missing), blocks)
        assertEquals(mapOf(2 to listOf(h)), placed)
    }

    @Test fun aHighlightBecomesAReplyableNote() {
        val h = highlight(listOf(listOf("e", articleId)))!!
        val note = h.toNote()
        assertEquals(ArticleEngagement.HIGHLIGHT_KIND, note.kind)
        assertEquals(h.id, note.id)
        assertEquals(NIP10Thread.COMMENT_KIND, NIP10Thread.replyKind(note.kind))
    }
}
