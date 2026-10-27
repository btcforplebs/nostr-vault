package com.nostrvault.data.local

import com.nostrvault.service.CustomEmoji
import kotlinx.serialization.Serializable

/**
 * One emoji the person can react with: Unicode ([custom] null, [content] the
 * emoji) or a NIP-30 custom emoji ([content] its `:shortcode:`).
 */
@Serializable
data class ReactionPick(
    val content: String,
    val shortcode: String? = null,
    val url: String? = null,
    val setAddress: String? = null,
) {
    val custom: CustomEmoji?
        get() = if (shortcode != null && url != null) CustomEmoji(shortcode, url, setAddress) else null

    /** Two picks are the same emoji: the same Unicode, or the same shortcode and image. */
    val key: String get() = if (url != null) "$content|$url" else content

    companion object {
        fun of(custom: CustomEmoji) = ReactionPick(custom.content, custom.shortcode, custom.url, custom.setAddress)
    }
}

/**
 * The quick bar and recents, kept on this phone only (Logen, 2026-10-27).
 * The bar has [QUICK_SLOTS] emoji the person can change, and orders itself
 * by how often each one is used. Recents are the last [RECENTS_MAX]
 * emoji reacted with, newest first. Pure, so the rules are testable.
 */
object EmojiPalette {
    const val QUICK_SLOTS = 6
    const val RECENTS_MAX = 24
    /** Use counts kept; the least used go first past this. */
    const val COUNTS_MAX = 200

    val DEFAULT_BAR = listOf("❤️", "🤙", "🔥", "😂", "😮", "😢").map { ReactionPick(it) }

    @Serializable
    data class State(
        val slots: List<ReactionPick> = DEFAULT_BAR,
        val counts: Map<String, Int> = emptyMap(),
        val recents: List<ReactionPick> = emptyList(),
    )

    /** [pick] was reacted with: newest in recents, one more use. */
    fun recordUse(state: State, pick: ReactionPick): State {
        val recents = (listOf(pick) + state.recents.filter { it.key != pick.key }).take(RECENTS_MAX)
        var counts = state.counts + (pick.key to (state.counts[pick.key] ?: 0) + 1)
        if (counts.size > COUNTS_MAX) {
            val keep = state.slots.map { it.key }.toSet() + pick.key
            val drop = counts.entries.filter { it.key !in keep }.sortedBy { it.value }
                .take(counts.size - COUNTS_MAX).map { it.key }.toSet()
            counts = counts - drop
        }
        return state.copy(recents = recents, counts = counts)
    }

    /** The bar, most used first; equal counts keep the order the person set. */
    fun orderedBar(state: State): List<ReactionPick> =
        state.slots.sortedByDescending { state.counts[it.key] ?: 0 }

    /**
     * Puts [pick] in the slot that [replacing] holds. When [pick] is already
     * on the bar the two swap places, so the bar never shows one emoji twice.
     */
    fun replaceSlot(state: State, replacing: ReactionPick, pick: ReactionPick): State {
        val slots = state.slots.toMutableList()
        val at = slots.indexOfFirst { it.key == replacing.key }
        if (at < 0 || replacing.key == pick.key) return state
        val existing = slots.indexOfFirst { it.key == pick.key }
        if (existing >= 0) slots[existing] = slots[at]
        slots[at] = pick
        return state.copy(slots = slots)
    }

    /** A saved state that is short, long or repeats an emoji is made whole again. */
    fun normalized(state: State): State {
        val unique = state.slots.distinctBy { it.key }.take(QUICK_SLOTS).toMutableList()
        for (fill in DEFAULT_BAR) {
            if (unique.size >= QUICK_SLOTS) break
            if (unique.none { it.key == fill.key }) unique += fill
        }
        return state.copy(slots = unique, recents = state.recents.distinctBy { it.key }.take(RECENTS_MAX))
    }
}
