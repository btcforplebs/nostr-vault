package com.nostrvault.ui.components

import com.nostrvault.data.local.EmojiCatalog
import com.nostrvault.data.local.EmojiPalette
import com.nostrvault.data.local.ReactionPick
import com.nostrvault.service.CustomEmoji
import com.nostrvault.service.EmojiListRepository
import com.nostrvault.ui.components.EmojiPickerSections.Kind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EmojiPickerSectionsTest {
    private val catalog = EmojiCatalog.parse(
        """
        # group: Smileys & Emotion
        😀	grinning face
        😂	face with tears of joy
        🤔	thinking face
        # group: People & Body
        👏	clapping hands
        👍	thumbs up
        """.trimIndent(),
    )
    private val pepe = CustomEmoji("pepe", "https://x.example/p.png")
    private val frog = CustomEmoji("frog_dance", "https://x.example/f.gif", "30030:${"c".repeat(64)}:frogs")
    private val library = EmojiListRepository.Library(
        owner = "me",
        single = listOf(pepe),
        sets = listOf(EmojiListRepository.EmojiSet(frog.setAddress!!, "Frogs", listOf(frog))),
    )
    private val palette = EmojiPalette.recordUse(EmojiPalette.State(), ReactionPick("😂"))
    private val sections = EmojiPickerSections.build(catalog, palette, library, custom = true)

    private fun search(q: String) = EmojiPickerSections.search(sections, catalog.names, q).map { it.content }

    @Test
    fun `custom puts recent, your emoji and each pack before the Unicode groups`() {
        assertEquals(
            listOf("Recent", "Your emoji", "Frogs", "Smileys & Emotion", "People & Body"),
            sections.map { it.title },
        )
        assertEquals(listOf(Kind.RECENT, Kind.YOURS, Kind.PACK, Kind.UNICODE, Kind.UNICODE), sections.map { it.kind })
        assertEquals(frog, sections[2].icon?.custom)
    }

    @Test
    fun `the default reaction offers Unicode only`() {
        val unicode = EmojiPickerSections.build(catalog, palette, library, custom = false)
        assertEquals(listOf("Smileys & Emotion", "People & Body"), unicode.map { it.title })
    }

    @Test
    fun `no recents and no emoji list leaves just the Unicode groups`() {
        val s = EmojiPickerSections.build(catalog, EmojiPalette.State(), EmojiListRepository.Library(), custom = true)
        assertEquals(2, s.size)
    }

    @Test
    fun `search finds Unicode emoji by name, best match first, each once`() {
        assertEquals(listOf("🤔"), search("thinking"))
        assertEquals(listOf("👏"), search("clap"))
        // "face" starts two names and is a later word in a third
        assertEquals(listOf("😂", "😀", "🤔"), search("face"))
        assertEquals(listOf("👍"), search("THUMBS"))
    }

    @Test
    fun `search puts custom shortcodes before Unicode names`() {
        assertEquals(listOf(":frog_dance:"), search("frog"))
        assertEquals(listOf(":pepe:"), search(":pepe:"))
        assertEquals(":frog_dance:", search("dance").first())
    }

    @Test
    fun `a typed emoji is offered even when it is not in the catalog`() {
        assertEquals(listOf("🦄"), search("🦄"))
        assertEquals(listOf("😂"), search("😂"))
        assertTrue(EmojiPickerSections.isEmojiText("❤️"))
        assertFalse(EmojiPickerSections.isEmojiText("ok"))
        assertFalse(EmojiPickerSections.isEmojiText(":)"))
    }

    @Test
    fun `nothing matches gives nothing`() {
        assertEquals(emptyList<String>(), search("zzzz"))
        assertEquals(emptyList<String>(), search("  "))
    }
}
