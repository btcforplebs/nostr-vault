package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class EmojiListParseTest {
    private val artist = "c".repeat(64)

    @Test
    fun `a 10030 gives its own emoji and the sets it adds`() {
        val parsed = EmojiListParse.list(
            listOf(
                listOf("emoji", "pepe", "https://x.example/p.png"),
                listOf("emoji", "bad shortcode", "https://x.example/b.png"),
                listOf("a", "30030:$artist:frogs"),
                listOf("a", "30030:$artist:frogs"),
                listOf("a", "30023:$artist:an-article"),
                listOf("a", "30030:not-hex:x"),
                listOf("p", artist),
            ),
        )
        assertEquals(listOf("pepe"), parsed.single.map { it.shortcode })
        assertEquals(listOf("30030:$artist:frogs"), parsed.setAddresses)
    }

    @Test
    fun `a set address keeps a d with colons`() {
        assertEquals(EmojiListParse.SetRef(artist, "a:b"), EmojiListParse.setRef("30030:$artist:a:b"))
        assertNull(EmojiListParse.setRef("30030:$artist"))
        assertNull(EmojiListParse.setRef("10030:$artist:x"))
    }

    @Test
    fun `a set's emoji know which set they came from`() {
        val address = "30030:$artist:frogs"
        val set = EmojiListParse.set(
            address,
            listOf(listOf("d", "frogs"), listOf("title", "Frog pack"), listOf("emoji", "pepe", "https://x.example/p.png")),
        )
        assertEquals("Frog pack", set.title)
        assertEquals(listOf(CustomEmoji("pepe", "https://x.example/p.png", address)), set.emojis)
        assertEquals("frogs", EmojiListParse.set(address, listOf(listOf("d", "frogs"))).title)
    }
}
