package com.nostrvault.ui.components

import com.nostrvault.data.local.EmojiPalette
import com.nostrvault.data.local.ReactionPick
import com.nostrvault.service.CustomEmoji
import com.nostrvault.service.EmojiListRepository
import org.junit.Assert.assertEquals
import org.junit.Test

class EmojiPickerTabsTest {
    private val categories = listOf(EmojiCategory("Smileys", "😀", listOf("😀", "😂")))
    private val pepe = CustomEmoji("pepe", "https://x.example/p.png")
    private val frog = CustomEmoji("frog_dance", "https://x.example/f.gif", "30030:${"c".repeat(64)}:frogs")
    private val library = EmojiListRepository.Library(
        owner = "me",
        single = listOf(pepe),
        sets = listOf(EmojiListRepository.EmojiSet(frog.setAddress!!, "Frogs", listOf(frog))),
    )
    private val palette = EmojiPalette.recordUse(EmojiPalette.State(), ReactionPick("😂"))

    @Test
    fun `reacting puts recents, your emoji and each set before the categories`() {
        val tabs = EmojiPickerTabs.build(categories, palette, library, reacting = true)
        assertEquals(listOf("Recents", "Your emoji", "Frogs", "Smileys"), tabs.map { it.name })
        assertEquals(listOf(":pepe:"), tabs[1].picks.map { it.content })
        assertEquals(frog, tabs[2].picks.single().custom)
    }

    @Test
    fun `choosing a default reaction offers Unicode only`() {
        val tabs = EmojiPickerTabs.build(categories, palette, library, reacting = false)
        assertEquals(listOf("Smileys"), tabs.map { it.name })
    }

    @Test
    fun `no recents and no emoji list leaves just the categories`() {
        val tabs = EmojiPickerTabs.build(categories, EmojiPalette.State(), EmojiListRepository.Library(), reacting = true)
        assertEquals(listOf("Smileys"), tabs.map { it.name })
    }

    @Test
    fun `search finds custom emoji by shortcode, each once`() {
        val tabs = EmojiPickerTabs.build(categories, palette, library, reacting = true)
        assertEquals(listOf(":frog_dance:"), EmojiPickerTabs.search(tabs, "FROG").map { it.content })
        assertEquals(listOf(":pepe:"), EmojiPickerTabs.search(tabs, ":pepe:").map { it.content })
        assertEquals(listOf("😂"), EmojiPickerTabs.search(tabs, "😂").map { it.content })
    }
}
