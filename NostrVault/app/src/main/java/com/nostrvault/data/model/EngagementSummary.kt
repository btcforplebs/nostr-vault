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

    /** How many emoji pills a thread note's row draws before a "+N" (iOS ThreadNoteEngagementRow). */
    const val THREAD_ROW_EMOJI_GROUPS = 3

    /**
     * What one note's row in the thread shows under the card when thread
     * stats are on: emoji groups, zaps and the sats they add up to, and how
     * many people reposted (each once). iOS: ThreadedReplyNode's
     * groupedReactionsForReply / zapTotalForReply / repostCountForReply.
     */
    data class ThreadRow(
        val emojiGroups: List<EmojiGroup>,
        val zapCount: Int,
        val zapSats: Long,
        val reposts: Int,
    ) {
        val isEmpty: Boolean get() = emojiGroups.isEmpty() && zapCount == 0 && reposts == 0
    }

    /** [details] as a thread row; reactions are dropped in Zaps Only mode. */
    fun threadRow(details: EngagementDetails, zapsOnly: Boolean): ThreadRow = ThreadRow(
        emojiGroups = if (zapsOnly) emptyList() else groupReactions(details.reactions),
        zapCount = details.zaps.size,
        zapSats = details.zaps.sumOf { it.amountSats },
        reposts = details.reposts.map { it.pubkey }.distinct().size,
    )

    /** "2,100": a sats total on its own, grouped like [zapText]. */
    fun satsText(totalSats: Long): String = NumberFormat.getIntegerInstance().format(totalSats)

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
