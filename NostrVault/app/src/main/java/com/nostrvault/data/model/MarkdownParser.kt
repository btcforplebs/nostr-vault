package com.nostrvault.data.model

/**
 * One block of an article body. iOS: `MarkdownBlock` (Models/LongFormContent.swift).
 */
sealed class MarkdownBlock {
    data class Heading(val level: Int, val text: String) : MarkdownBlock()
    data class Paragraph(val text: String) : MarkdownBlock()
    data class Bullet(val text: String) : MarkdownBlock()
    data class Ordered(val index: Int, val text: String) : MarkdownBlock()
    data class Quote(val text: String) : MarkdownBlock()
    data class Code(val text: String) : MarkdownBlock()
    data class Image(val url: String) : MarkdownBlock()
    data object Rule : MarkdownBlock()

    /** The markdown of a block a reader can highlight; null for code, images and rules. */
    val highlightableText: String?
        get() = when (this) {
            is Heading -> text
            is Paragraph -> text
            is Bullet -> text
            is Ordered -> text
            is Quote -> text
            is Code, is Image, Rule -> null
        }
}

/**
 * Splits a markdown body into the blocks the article reader draws. A port of
 * iOS `MarkdownParser.parse`, branch for branch. Consecutive non-blank lines
 * join into one paragraph, so hard-wrapped source does not render as a stack
 * of one-line paragraphs.
 */
object MarkdownParser {
    private val imageExtensions = setOf("jpg", "jpeg", "png", "gif", "webp", "heic", "bmp")

    fun parse(body: String): List<MarkdownBlock> {
        val blocks = mutableListOf<MarkdownBlock>()
        val paragraph = mutableListOf<String>()
        val codeLines = mutableListOf<String>()
        var inCodeFence = false

        fun flushParagraph() {
            if (paragraph.isEmpty()) return
            val text = paragraph.joinToString(" ").trim(' ', '\t')
            paragraph.clear()
            if (text.isEmpty()) return
            // A paragraph that is nothing but an image link becomes an image block.
            blocks.add(standaloneImageUrl(text)?.let { MarkdownBlock.Image(it) } ?: MarkdownBlock.Paragraph(text))
        }

        for (rawLine in body.lines()) {
            val line = rawLine.trim(' ', '\t')

            if (line.startsWith("```")) {
                if (inCodeFence) {
                    blocks.add(MarkdownBlock.Code(codeLines.joinToString("\n")))
                    codeLines.clear()
                    inCodeFence = false
                } else {
                    flushParagraph()
                    inCodeFence = true
                }
                continue
            }
            if (inCodeFence) {
                codeLines.add(rawLine)
                continue
            }
            if (line.isEmpty()) {
                flushParagraph()
                continue
            }
            if (line.startsWith("#")) {
                val hashes = line.takeWhile { it == '#' }.length
                // CommonMark needs whitespace after the hashes, or a line that
                // opens with a hashtag would render as a giant H1.
                val afterHashes = line.drop(hashes)
                if (hashes <= 6 && (afterHashes.startsWith(" ") || afterHashes.startsWith("\t"))) {
                    val text = afterHashes.trim(' ', '\t')
                    if (text.isNotEmpty()) {
                        flushParagraph()
                        blocks.add(MarkdownBlock.Heading(hashes, text))
                        continue
                    }
                }
            }
            if (line == "---" || line == "***" || line == "___") {
                flushParagraph()
                blocks.add(MarkdownBlock.Rule)
                continue
            }
            if (line.startsWith("> ") || line == ">") {
                flushParagraph()
                blocks.add(MarkdownBlock.Quote(line.drop(1).trim(' ', '\t')))
                continue
            }
            if (line.startsWith("- ") || line.startsWith("* ") || line.startsWith("+ ")) {
                flushParagraph()
                val text = line.drop(2).trim(' ', '\t')
                blocks.add(standaloneImageUrl(text)?.let { MarkdownBlock.Image(it) } ?: MarkdownBlock.Bullet(text))
                continue
            }
            val ordered = orderedListItem(line)
            if (ordered != null) {
                flushParagraph()
                blocks.add(MarkdownBlock.Ordered(ordered.first, ordered.second))
                continue
            }

            paragraph.add(line)
        }

        if (inCodeFence && codeLines.isNotEmpty()) blocks.add(MarkdownBlock.Code(codeLines.joinToString("\n")))
        flushParagraph()
        return blocks
    }

    /** `1. text` / `12) text` -> (1, "text"); null for anything else. */
    internal fun orderedListItem(line: String): Pair<Int, String>? {
        val digits = line.takeWhile { it.isDigit() }
        if (digits.isEmpty() || digits.length > 3) return null
        val index = digits.toIntOrNull() ?: return null
        val rest = line.drop(digits.length)
        val separator = rest.firstOrNull() ?: return null
        if (separator != '.' && separator != ')') return null
        val text = rest.drop(1).trim(' ', '\t')
        if (text.isEmpty()) return null
        return index to text
    }

    /** The URL when [text] is only an image: `![alt](url)` or a bare http(s) URL with an image extension. */
    internal fun standaloneImageUrl(text: String): String? {
        if (text.startsWith("![") && text.endsWith(")")) {
            val open = text.lastIndexOf('(')
            if (open >= 0) {
                val inner = text.substring(open + 1, text.length - 1)
                val urlPart = inner.split(' ').firstOrNull { it.isNotEmpty() } ?: inner
                return urlPart.takeIf { it.isNotEmpty() }
            }
        }
        if (text.contains(' ')) return null
        val uri = runCatching { java.net.URI(text) }.getOrNull() ?: return null
        if (uri.scheme?.startsWith("http") != true) return null
        val ext = uri.path.orEmpty().substringAfterLast('/').substringAfterLast('.', "").lowercase()
        return if (ext in imageExtensions) text else null
    }
}
