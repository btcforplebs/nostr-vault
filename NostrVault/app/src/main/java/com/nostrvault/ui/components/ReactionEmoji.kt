package com.nostrvault.ui.components

import java.text.BreakIterator

private const val HEART = "❤️"
private const val THUMBS_DOWN = "👎"

/**
 * Maps raw kind-7 reaction content to a displayable emoji.
 * "+"/empty is a standard like (heart), "-" a dislike; custom-emoji
 * shortcodes and plain text fall back to the heart.
 */
fun reactionDisplayEmoji(raw: String): String {
    val trimmed = raw.trim()
    when (trimmed) {
        "", "+", "+1", "❤", HEART -> return HEART
        "-", "-1" -> return THUMBS_DOWN
    }
    val iterator = BreakIterator.getCharacterInstance()
    iterator.setText(trimmed)
    var start = iterator.first()
    var end = iterator.next()
    while (end != BreakIterator.DONE) {
        val grapheme = trimmed.substring(start, end)
        if (isEmojiGrapheme(grapheme)) return grapheme
        start = end
        end = iterator.next()
    }
    return HEART
}

/** Unique display emojis for a set of raw reaction contents, in first-seen order. */
fun reactionEmojiSummary(emojis: List<String>, limit: Int): String {
    val unique = LinkedHashSet<String>()
    for (raw in emojis) {
        unique.add(reactionDisplayEmoji(raw))
        if (unique.size == limit) break
    }
    return if (unique.isEmpty()) HEART else unique.joinToString("")
}

private fun isEmojiGrapheme(grapheme: String): Boolean {
    // Variation selector (FE0F) or ZWJ (200D) marks an emoji sequence
    if (grapheme.contains('\uFE0F') || grapheme.contains('\u200D')) return true
    val cp = grapheme.codePointAt(0)
    return cp in 0x1F000..0x1FAFF || cp in 0x2600..0x27BF ||
        cp in 0x1F1E6..0x1F1FF || cp in 0x2B00..0x2BFF
}

/**
 * The toast after a like is signed and sent: "Liked" for a plain like (no
 * emoji chosen, or a heart), else "Reacted" with the emoji.
 */
fun likedToastMessage(emoji: String?): String {
    val shown = emoji?.let(::reactionDisplayEmoji) ?: return "Liked"
    return if (shown == HEART) "Liked" else "Reacted $shown"
}
