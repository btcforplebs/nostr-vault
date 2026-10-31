package com.nostrvault.data.local

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class EmojiCatalogTest {
    /** The tsv the app ships (unit tests run with the module as working directory). */
    private val shipped = File("src/main/assets/${EmojiCatalog.ASSET}").readText()

    @Test
    fun `the shipped list has the nine Unicode groups and names`() {
        val catalog = EmojiCatalog.parse(shipped)
        assertEquals(
            listOf(
                "Smileys & Emotion", "People & Body", "Animals & Nature", "Food & Drink",
                "Travel & Places", "Activities", "Objects", "Symbols", "Flags",
            ),
            catalog.groups.map { it.name },
        )
        assertTrue(catalog.groups.sumOf { it.entries.size } > 1500)
        assertEquals("thinking face", catalog.names["🤔"])
        assertEquals("clapping hands", catalog.names["👏"])
    }

    @Test
    fun `skin tone variants are left out`() {
        val all = EmojiCatalog.parse(shipped).groups.flatMap { it.entries }.map { it.emoji }
        assertFalse(all.any { e -> e.codePoints().anyMatch { it in 0x1F3FB..0x1F3FF } })
        assertEquals(all.size, all.toSet().size)
    }

    @Test
    fun `emoji the phone cannot draw are dropped, and an emptied group with them`() {
        val text = "# group: A\n😀\tgrinning face\n# group: B\n🫩\tface with bags under eyes\n"
        val catalog = EmojiCatalog.parse(text) { it != "🫩" }
        assertEquals(listOf("A"), catalog.groups.map { it.name })
    }
}
