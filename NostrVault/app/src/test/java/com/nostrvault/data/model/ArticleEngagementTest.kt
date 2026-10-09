package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/** Mirrors HavenApp/MediaLogicTests/Tests/MediaLogicTests/ArticleEngagementTests.swift. */
class ArticleEngagementTest {
    private val id = "a".repeat(64)
    private val author = "b".repeat(64)
    private val relay = "wss://relay.example"
    private val articleTags = listOf(listOf("d", "my-post"), listOf("title", "Hi"))

    @Test fun reactionOnArticleNamesCoordinateAndVersion() {
        assertEquals(
            listOf(
                listOf("e", id, relay, author),
                listOf("a", "30023:$author:my-post", relay),
                listOf("p", author),
                listOf("k", "30023"),
            ),
            ArticleEngagement.reactionTags(id, 30023, author, articleTags, relay),
        )
    }

    @Test fun reactionOnNoteHasNoCoordinate() {
        assertFalse(ArticleEngagement.reactionTags(id, 1, author, emptyList(), relay).any { it.first() == "a" })
    }

    @Test fun highlightOfTrimmedPassageKeepsContextAndComment() {
        assertEquals(
            listOf(
                listOf("a", "30023:$author:my-post", relay),
                listOf("e", id, relay),
                listOf("p", author, relay, "author"),
                listOf("context", "Before the good part after."),
                listOf("comment", "so true"),
                listOf("alt", "Highlight: \"the good part\""),
            ),
            ArticleEngagement.highlightTags(id, 30023, author, articleTags, relay,
                " the good part ", "Before the good part after.", " so true "),
        )
    }

    @Test fun wholeParagraphHighlightDropsRedundantContextAndEmptyComment() {
        val tags = ArticleEngagement.highlightTags(id, 30023, author, articleTags, relay, "All of it.", "All of it.\n", "  ")
        assertFalse(tags.any { it.first() == "context" })
        assertFalse(tags.any { it.first() == "comment" })
    }

    @Test fun plainTextStripsInlineMarkdown() {
        assertEquals("A bold link word", ArticleEngagement.plainText("A **bold** [link](https://x.y) word"))
        assertEquals("Title", ArticleEngagement.plainText("## Title"))
    }

    @Test fun blocksSplitOnBlankLinesButKeepCodeWhole() {
        val md = "# Head\n\nOne\ntwo\n\n```\na\n\nb\n```\n\nLast"
        assertEquals(listOf("# Head", "One\ntwo", "```\na\n\nb\n```", "Last"), ArticleEngagement.blocks(md))
    }
}
