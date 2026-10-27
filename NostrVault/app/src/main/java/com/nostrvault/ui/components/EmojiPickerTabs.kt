package com.nostrvault.ui.components

import com.nostrvault.data.local.EmojiPalette
import com.nostrvault.data.local.ReactionPick
import com.nostrvault.service.EmojiListRepository

/** The picker's tabs. Pure, so what shows where is testable apart from the sheet. */
internal object EmojiPickerTabs {
    data class Tab(val name: String, val icon: ReactionPick, val picks: List<ReactionPick>)

    /**
     * When [reacting]: Recents (if any), Your emoji (the 10030's own emoji, if
     * any), one tab per set it added, then the Unicode categories. Otherwise
     * the categories alone, as before.
     */
    fun build(
        categories: List<EmojiCategory>,
        palette: EmojiPalette.State,
        library: EmojiListRepository.Library,
        reacting: Boolean,
    ): List<Tab> {
        val unicode = categories.map { cat -> Tab(cat.name, ReactionPick(cat.icon), cat.emojis.map { ReactionPick(it) }) }
        if (!reacting) return unicode
        val out = mutableListOf<Tab>()
        if (palette.recents.isNotEmpty()) out += Tab("Recents", ReactionPick("🕒"), palette.recents)
        if (library.single.isNotEmpty()) {
            out += Tab("Your emoji", ReactionPick("⭐"), library.single.map { ReactionPick.of(it) })
        }
        for (set in library.sets) {
            if (set.emojis.isEmpty()) continue
            val picks = set.emojis.map { ReactionPick.of(it) }
            out += Tab(set.title, picks.first(), picks)
        }
        return out + unicode
    }

    /** Every tab's emoji whose shortcode or Unicode contains [query], once each. */
    fun search(tabs: List<Tab>, query: String): List<ReactionPick> {
        val q = query.trim().lowercase().removePrefix(":").removeSuffix(":")
        if (q.isEmpty()) return emptyList()
        return tabs.flatMap { it.picks }
            .filter { pick -> pick.shortcode?.lowercase()?.contains(q) ?: pick.content.lowercase().contains(q) }
            .distinctBy { it.key }
    }
}
