package com.nostrvault.data.model

import java.text.BreakIterator
import java.text.NumberFormat

/**
 * What the note detail's compact engagement row shows: reactions grouped by
 * emoji, and zaps as "count · total sats". iOS: groupedReactions and
 * compactZapText in NoteDetailView.swift.
 */
object EngagementSummary {

    data class EmojiGroup(val emoji: String, val count: Int)

    /** How many emoji pills the row draws before a "+N". */
    const val VISIBLE_EMOJI_GROUPS = 4

    /**
     * Reactions grouped by emoji, most used first (ties keep first-seen
     * order). Anything longer than four characters, such as a `:shortcode:`
     * custom emoji, is left out: it is a word, not a pill.
     */
    fun groupReactions(reactions: List<ReactionDetail>): List<EmojiGroup> {
        val counts = LinkedHashMap<String, Int>()
        for (reaction in reactions) {
            val emoji = reaction.emoji.ifBlank { "+" }.let { if (it == "+") "❤️" else it }
            if (graphemeCount(emoji) > 4) continue
            counts[emoji] = (counts[emoji] ?: 0) + 1
        }
        return counts.entries
            .map { EmojiGroup(it.key, it.value) }
            .sortedByDescending { it.count }
    }

    /** "3 · 2,100": how many zaps, and the sats they add up to. */
    fun zapText(zapCount: Int, totalSats: Long): String =
        "$zapCount · ${NumberFormat.getIntegerInstance().format(totalSats)}"

    /** User-perceived characters, so a flag or a skin-toned emoji counts once. */
    private fun graphemeCount(text: String): Int {
        val it = BreakIterator.getCharacterInstance()
        it.setText(text)
        var count = 0
        while (it.next() != BreakIterator.DONE) count++
        return count
    }
}
