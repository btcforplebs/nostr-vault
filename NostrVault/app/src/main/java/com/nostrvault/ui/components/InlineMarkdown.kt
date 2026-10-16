package com.nostrvault.ui.components

/** A stretch of note text and the inline styles on it. */
internal data class MarkdownRun(
    val text: String,
    val bold: Boolean = false,
    val italic: Boolean = false,
    val strike: Boolean = false,
    val code: Boolean = false,
)

/**
 * The inline markdown the iPhone renders in a note (`NostrContentFormatter`,
 * `AttributedString(markdown:)` with `.inlineOnlyPreservingWhitespace`):
 * **bold**, *italic*, ~~strikethrough~~ and `code`, plus backslash escapes.
 * Links the author typed are not links on iOS either (`MarkdownEscape`), so
 * brackets stay text. Whitespace and line breaks are kept as typed.
 *
 * Follows CommonMark's main rules: a delimiter opens only before a non-space
 * and closes only after one, and `_` never works inside a word (snake_case).
 * Anything that does not close is shown as typed.
 */
internal object InlineMarkdown {

    fun parse(text: String): List<MarkdownRun> {
        if (text.none { it == '*' || it == '_' || it == '~' || it == '`' || it == '\\' }) {
            return if (text.isEmpty()) emptyList() else listOf(MarkdownRun(text))
        }
        val out = mutableListOf<MarkdownRun>()
        parseInto(text, MarkdownRun(""), out, depth = 0)
        return merge(out)
    }

    private fun parseInto(s: String, style: MarkdownRun, out: MutableList<MarkdownRun>, depth: Int) {
        // A search for a closer that failed from one place fails from any later
        // one too, so remember it: otherwise a note full of openers that never
        // close is scanned to the end once per opener.
        val noCloserFrom = HashMap<Int, Int>()
        val plain = StringBuilder()
        fun flush() {
            if (plain.isNotEmpty()) out += style.copy(text = plain.toString())
            plain.clear()
        }
        var i = 0
        while (i < s.length) {
            val c = s[i]
            when {
                c == '\\' && i + 1 < s.length && s[i + 1] in ESCAPABLE -> {
                    plain.append(s[i + 1]); i += 2
                }
                c == '`' -> {
                    val n = runLength(s, i, '`')
                    val fence = "`".repeat(n)
                    var close = s.indexOf(fence, i + n)
                    while (close >= 0 && runLength(s, close, '`') != n) close = s.indexOf(fence, close + runLength(s, close, '`'))
                    if (close < 0) {
                        plain.append(fence); i += n
                    } else {
                        flush()
                        var inner = s.substring(i + n, close)
                        if (inner.length >= 2 && inner.first() == ' ' && inner.last() == ' ' && inner.isNotBlank()) {
                            inner = inner.substring(1, inner.length - 1)
                        }
                        out += style.copy(text = inner, code = true)
                        i = close + n
                    }
                }
                c == '~' || c == '*' || c == '_' -> {
                    val n = runLength(s, i, c)
                    val key = c.code * 8 + n
                    val close = if (depth < MAX_DEPTH && opens(s, i, n, c) && i + n < (noCloserFrom[key] ?: Int.MAX_VALUE)) {
                        findCloser(s, i + n, n, c).also { if (it < 0) noCloserFrom[key] = i + n }
                    } else {
                        -1
                    }
                    if (close < 0) {
                        plain.append(s, i, i + n); i += n
                    } else {
                        flush()
                        val inner = s.substring(i + n, close)
                        val styled = when {
                            c == '~' -> style.copy(strike = true)
                            n == 1 -> style.copy(italic = true)
                            n == 2 -> style.copy(bold = true)
                            else -> style.copy(bold = true, italic = true)
                        }
                        parseInto(inner, styled, out, depth + 1)
                        i = close + n
                    }
                }
                else -> {
                    plain.append(c); i++
                }
            }
        }
        flush()
    }

    /** `~~` only (one tilde is text, as on iOS), and `*`/`_` runs of one to three. */
    private fun opens(s: String, i: Int, n: Int, c: Char): Boolean {
        if (c == '~' && n != 2) return false
        if (n > 3) return false
        val next = s.getOrNull(i + n) ?: return false
        if (next.isWhitespace()) return false
        if (c == '_' && s.getOrNull(i - 1)?.isLetterOrDigit() == true) return false
        return true
    }

    /** The next run of exactly [n] [c]s that can close: after a non-space, and for `_` not before a letter. */
    private fun findCloser(s: String, from: Int, n: Int, c: Char): Int {
        var j = from
        while (j < s.length) {
            if (s[j] == '\\') { j += 2; continue }
            if (s[j] == '`') {
                // A code span inside wins over a delimiter in it.
                val m = runLength(s, j, '`')
                val end = s.indexOf("`".repeat(m), j + m)
                j = if (end < 0) j + m else end + m
                continue
            }
            if (s[j] != c) { j++; continue }
            val m = runLength(s, j, c)
            val before = s.getOrNull(j - 1)
            val after = s.getOrNull(j + m)
            if (m == n && j > from && before != null && !before.isWhitespace() &&
                !(c == '_' && after?.isLetterOrDigit() == true)
            ) return j
            j += m
        }
        return -1
    }

    private fun runLength(s: String, i: Int, c: Char): Int {
        var j = i
        while (j < s.length && s[j] == c) j++
        return j - i
    }

    /** Joins neighbours with the same style, so an escape does not split a run. */
    private fun merge(runs: List<MarkdownRun>): List<MarkdownRun> {
        val out = mutableListOf<MarkdownRun>()
        for (run in runs) {
            if (run.text.isEmpty()) continue
            val last = out.lastOrNull()
            if (last != null && last.copy(text = "") == run.copy(text = "")) {
                out[out.lastIndex] = last.copy(text = last.text + run.text)
            } else {
                out += run
            }
        }
        return out
    }

    /** Styles nest this deep at most; deeper markers are shown as typed. */
    private const val MAX_DEPTH = 6

    private const val ESCAPABLE = "\\`*_{}[]()#+-.!~|<>"
}
