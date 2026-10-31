package com.nostrvault.ui.components

import com.nostrvault.data.local.EmojiCatalog
import com.nostrvault.data.local.EmojiPalette
import com.nostrvault.data.local.ReactionPick
import com.nostrvault.service.EmojiListRepository

/**
 * What the picker grid shows, in order, and its search. Pure, so what shows
 * where is testable apart from the sheet. Modeled on Amethyst: one grid with
 * a header per section and a strip of section icons that jumps between them.
 */
internal object EmojiPickerSections {
    enum class Kind { RECENT, YOURS, PACK, UNICODE }

    /** [icon] is the pack's first emoji for [Kind.PACK]; the strip draws the rest from [kind] and [title]. */
    data class Section(val kind: Kind, val title: String, val picks: List<ReactionPick>, val icon: ReactionPick? = null)

    /**
     * With [custom] (reacting, or inserting into a note): Recent (if any),
     * Your emoji (the 10030's own, if any), one section per pack it added,
     * then every Unicode group. Otherwise (the default reaction) Unicode only.
     */
    fun build(
        catalog: EmojiCatalog,
        palette: EmojiPalette.State,
        library: EmojiListRepository.Library,
        custom: Boolean,
    ): List<Section> {
        val unicode = catalog.groups.map { g -> Section(Kind.UNICODE, g.name, g.entries.map { ReactionPick(it.emoji) }) }
        if (!custom) return unicode
        val out = mutableListOf<Section>()
        if (palette.recents.isNotEmpty()) out += Section(Kind.RECENT, "Recent", palette.recents)
        if (library.single.isNotEmpty()) {
            out += Section(Kind.YOURS, "Your emoji", library.single.map { ReactionPick.of(it) })
        }
        for (set in library.sets) {
            if (set.emojis.isEmpty()) continue
            val picks = set.emojis.map { ReactionPick.of(it) }
            out += Section(Kind.PACK, set.title, picks, icon = picks.first())
        }
        return out + unicode
    }

    /**
     * Search across every section, once per emoji. Custom emoji whose
     * shortcode matches come first, then Unicode emoji by name: exact, then
     * starts with, then a word starts with, then contains. Typing or pasting
     * an emoji offers that emoji first, so any emoji can still be sent.
     */
    fun search(sections: List<Section>, names: Map<String, String>, query: String): List<ReactionPick> {
        val raw = query.trim()
        if (raw.isEmpty()) return emptyList()
        val q = raw.lowercase().removePrefix(":").removeSuffix(":")
        val all = sections.flatMap { it.picks }.distinctBy { it.key }
        val typed = if (isEmojiText(raw)) listOf(ReactionPick(raw)) else emptyList()
        if (q.isEmpty()) return typed

        val custom = all.filter { it.shortcode != null }
            .mapNotNull { pick -> rank(pick.shortcode!!.lowercase(), q)?.let { pick to it } }
            .sortedBy { it.second }
            .map { it.first }
        val unicode = all.filter { it.shortcode == null }
            .mapNotNull { pick -> names[pick.content]?.let { rank(it.lowercase(), q) }?.let { pick to it } }
            .sortedBy { it.second }
            .map { it.first }
        return (typed + custom + unicode).distinctBy { it.key }
    }

    /** 0 exact, 1 starts with, 2 a word starts with, 3 contains; null no match. */
    private fun rank(name: String, q: String): Int? = when {
        name == q -> 0
        name.startsWith(q) -> 1
        name.split(' ', '_', '-', ':').any { it.startsWith(q) } -> 2
        name.contains(q) -> 3
        else -> null
    }

    /** No letters, digits or spaces, and something past basic Latin: an emoji typed or pasted in. */
    fun isEmojiText(text: String): Boolean =
        text.isNotEmpty() && text.length <= 32 &&
            text.none { it.isLetterOrDigit() || it.isWhitespace() } &&
            text.any { it.code >= 0x2000 }
}
