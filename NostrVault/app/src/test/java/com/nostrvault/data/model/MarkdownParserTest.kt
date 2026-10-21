package com.nostrvault.data.model

import com.nostrvault.data.model.MarkdownBlock.*
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Same cases as iOS MarkdownParser.parse, branch by branch. */
class MarkdownParserTest {
    @Test
    fun `hard-wrapped lines join into one paragraph, blank line splits`() {
        assertEquals(
            listOf(Paragraph("one two"), Paragraph("three")),
            MarkdownParser.parse("one\n  two\n\nthree"),
        )
    }

    @Test
    fun `headings need whitespace after at most six hashes`() {
        assertEquals(
            listOf(Heading(1, "Title"), Heading(3, "Sub"), Paragraph("#nostr tag ####### seven")),
            MarkdownParser.parse("# Title\n### Sub\n\n#nostr tag\n####### seven"),
        )
        assertEquals(listOf(Paragraph("#")), MarkdownParser.parse("# "))
    }

    @Test
    fun `rules quotes bullets and ordered items`() {
        assertEquals(
            listOf(Rule, Quote("said"), Quote(""), Bullet("a"), Bullet("b"), Bullet("c"), Ordered(12, "twelve"), Ordered(1, "one")),
            MarkdownParser.parse("---\n> said\n>\n- a\n* b\n+ c\n12) twelve\n1. one"),
        )
    }

    @Test
    fun `ordered items need a separator, text and at most three digits`() {
        assertNull(MarkdownParser.orderedListItem("1234. x"))
        assertNull(MarkdownParser.orderedListItem("1. "))
        assertNull(MarkdownParser.orderedListItem("1 x"))
        assertEquals(listOf(Paragraph("2026 was a year")), MarkdownParser.parse("2026 was a year"))
    }

    @Test
    fun `code fences keep raw lines and close at end of body`() {
        assertEquals(
            listOf(Paragraph("before"), Code("  let x = 1\n\nlet y"), Paragraph("after")),
            MarkdownParser.parse("before\n```swift\n  let x = 1\n\nlet y\n```\nafter"),
        )
        assertEquals(listOf(Code("open")), MarkdownParser.parse("```\nopen"))
        // As on iOS: the empty line after an unclosed fence is a code line.
        assertEquals(listOf(Code("")), MarkdownParser.parse("```\n"))
        assertEquals(emptyList<MarkdownBlock>(), MarkdownParser.parse("```"))
    }

    @Test
    fun `standalone images become image blocks`() {
        assertEquals(
            listOf(
                Image("https://x.com/a.png"),
                Image("https://x.com/b.JPG?w=2"),
                Image("https://x.com/c.webp"),
                Paragraph("see https://x.com/a.png"),
                Paragraph("https://x.com/page"),
            ),
            MarkdownParser.parse(
                "![alt](https://x.com/a.png \"t\")\n\nhttps://x.com/b.JPG?w=2\n\n- ![](https://x.com/c.webp)\n\n" +
                    "see https://x.com/a.png\n\nhttps://x.com/page",
            ),
        )
    }

    @Test
    fun `only text blocks are highlightable`() {
        assertEquals("p", Paragraph("p").highlightableText)
        assertNull(Code("c").highlightableText)
        assertNull(Image("u").highlightableText)
        assertNull(Rule.highlightableText)
    }
}
