package com.nostrvault.ui.screens

import com.nostrvault.service.CustomEmoji

/**
 * Custom emoji in the composer (NIP-30): the `:name` being typed, the emoji
 * that match it, putting one in, and the `emoji` tags a post needs. Pure, so
 * the rules are testable apart from the screen. iOS: `ComposeEmoji.swift`.
 */
object ComposeEmoji {
    /** Suggestions start after this many letters, so a lone `:` or `:)` stays quiet. */
    const val MIN_QUERY = 2
    const val MAX_SUGGESTIONS = 8

    data class Query(val start: Int, val end: Int, val text: String)

    private fun isShortcodeChar(c: Char) = c.isLetterOrDigit() && c.code < 128 || c == '_' || c == '-'

    /**
     * The `:name` the caret is at the end of, or null. The `:` must start a
     * word, so a time ("12:30") or a URL ("https://") doesn't count, and the
     * name is at least [MIN_QUERY] shortcode characters.
     */
    fun queryAt(text: String, caret: Int): Query? {
        val end = caret.coerceIn(0, text.length)
        var i = end
        while (i > 0 && isShortcodeChar(text[i - 1])) i--
        if (i == 0 || text[i - 1] != ':') return null
        val colon = i - 1
        if (colon > 0 && !text[colon - 1].isWhitespace()) return null
        val name = text.substring(i, end)
        if (name.length < MIN_QUERY) return null
        return Query(colon, end, name)
    }

    /**
     * The emoji whose shortcode contains [query], once each by shortcode:
     * those that start with it first, then the rest, each in [known] order
     * (recents first, then your emoji and sets).
     */
    fun suggestions(query: String, known: List<CustomEmoji>, limit: Int = MAX_SUGGESTIONS): List<CustomEmoji> {
        val q = query.lowercase()
        val unique = known.distinctBy { it.shortcode }.filter { it.shortcode.lowercase().contains(q) }
        val (starts, rest) = unique.partition { it.shortcode.lowercase().startsWith(q) }
        return (starts + rest).take(limit)
    }

    /** [text] with [query] replaced by `:shortcode: `, and the caret after it. */
    fun insert(text: String, query: Query, emoji: CustomEmoji): Pair<String, Int> {
        val replacement = emoji.content + " "
        val end = query.end.coerceAtMost(text.length)
        val start = query.start.coerceIn(0, end)
        return (text.substring(0, start) + replacement + text.substring(end)) to (start + replacement.length)
    }

    /**
     * [insertion] (an emoji, Unicode or `:shortcode:`) put in at [caret], with
     * a space before it when it would join the previous word, and the caret after it.
     */
    fun insertAt(text: String, caret: Int, insertion: String): Pair<String, Int> {
        val at = caret.coerceIn(0, text.length)
        val custom = insertion.startsWith(":")
        val before = if (custom && at > 0 && !text[at - 1].isWhitespace()) " " else ""
        val after = if (custom) " " else ""
        val piece = before + insertion + after
        return (text.substring(0, at) + piece + text.substring(at)) to (at + piece.length)
    }

    /**
     * One `emoji` tag per shortcode the post uses that [known] has an image
     * for, in the order they first appear. A `:word:` with no image gets none.
     */
    fun tags(content: String, known: Map<String, CustomEmoji>): List<List<String>> =
        CustomEmoji.segments(content, known)
            .mapNotNull { (it as? CustomEmoji.Segment.Emoji)?.emoji }
            .distinctBy { it.shortcode }
            .map { it.tag() }
}
