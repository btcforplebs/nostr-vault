package com.nostrvault.ui.components

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class InlineMarkdownTest {
    private fun parse(s: String) = InlineMarkdown.parse(s)
    private fun plain(s: String) = MarkdownRun(s)

    @Test
    fun `plain text is one run`() {
        assertEquals(listOf(plain("just words")), parse("just words"))
        assertEquals(emptyList<MarkdownRun>(), parse(""))
    }

    @Test
    fun `bold, italic, strikethrough and code`() {
        assertEquals(listOf(plain("a "), MarkdownRun("b", bold = true), plain(" c")), parse("a **b** c"))
        assertEquals(listOf(MarkdownRun("b", bold = true)), parse("__b__"))
        assertEquals(listOf(plain("a "), MarkdownRun("b", italic = true)), parse("a *b*"))
        assertEquals(listOf(MarkdownRun("b", italic = true)), parse("_b_"))
        assertEquals(listOf(MarkdownRun("gone", strike = true)), parse("~~gone~~"))
        assertEquals(listOf(plain("run "), MarkdownRun("ls -a", code = true)), parse("run `ls -a`"))
        assertEquals(listOf(MarkdownRun("both", bold = true, italic = true)), parse("***both***"))
    }

    @Test
    fun `styles nest`() {
        assertEquals(
            listOf(MarkdownRun("a ", bold = true), MarkdownRun("b", bold = true, italic = true), MarkdownRun(" c", bold = true)),
            parse("**a *b* c**"),
        )
    }

    @Test
    fun `code is literal inside`() {
        assertEquals(listOf(MarkdownRun("**not bold**", code = true)), parse("`**not bold**`"))
        assertEquals(listOf(MarkdownRun("a`b", code = true)), parse("``a`b``"))
    }

    @Test
    fun `markers that do not open or close stay as typed`() {
        assertEquals(listOf(plain("2 * 3 * 4")), parse("2 * 3 * 4"))
        assertEquals(listOf(plain("snake_case_name")), parse("snake_case_name"))
        assertEquals(listOf(plain("**open only")), parse("**open only"))
        assertEquals(listOf(plain("~one~")), parse("~one~"))
        assertEquals(listOf(plain("a ` b")), parse("a ` b"))
        assertEquals(listOf(plain("****")), parse("****"))
        assertEquals(listOf(plain("a ** b ** c")), parse("a ** b ** c"))
    }

    @Test
    fun `backslash escapes show the character`() {
        assertEquals(listOf(plain("*not italic*")), parse("\\*not italic\\*"))
        assertEquals(listOf(plain("C:\\path")), parse("C:\\path"))
    }

    /** Typed links stay text, as on iOS (MarkdownEscape): no link styling or target. */
    @Test
    fun `link syntax is text`() {
        assertEquals(listOf(plain("[jack](nostr:npub1x)")), parse("[jack](nostr:npub1x)"))
    }

    @Test
    fun `line breaks and spacing are kept`() {
        assertEquals(listOf(plain("one\n\n  "), MarkdownRun("two", bold = true), plain("\nthree")), parse("one\n\n  **two**\nthree"))
    }

    /** Notes come from strangers: no stack overflow and no quadratic scan on a crafted one. */
    @Test
    fun `a crafted note parses quickly and safely`() {
        val crafted = listOf(
            " _a".repeat(60_000),
            "*a**a".repeat(40_000),
            "**a ".repeat(50_000) + "b" + " a**".repeat(50_000),
            "`a``".repeat(50_000),
        )
        for (s in crafted) {
            val start = System.nanoTime()
            val runs = parse(s)
            val ms = (System.nanoTime() - start) / 1_000_000
            assertTrue("${s.take(8)}… took $ms ms", ms < 3_000)
            assertTrue(runs.sumOf { it.text.length } <= s.length)
        }
    }
}
