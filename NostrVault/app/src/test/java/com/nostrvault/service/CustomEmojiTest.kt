package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CustomEmojiTest {
    private val set = "30030:${"b".repeat(64)}:frogs"

    @Test
    fun `an emoji tag gives shortcode, image and set`() {
        assertEquals(
            CustomEmoji("pepe", "https://x.example/p.png", set),
            CustomEmoji.fromTag(listOf("emoji", "pepe", "https://x.example/p.png", set)),
        )
        assertEquals(CustomEmoji("soap_box-2", "http://x.example/s.gif"), CustomEmoji.fromTag(listOf("emoji", "soap_box-2", "http://x.example/s.gif")))
    }

    @Test
    fun `bad shortcodes and addresses are refused`() {
        assertNull(CustomEmoji.fromTag(listOf("emoji", "pe pe", "https://x.example/p.png")))
        assertNull(CustomEmoji.fromTag(listOf("emoji", "pepe:", "https://x.example/p.png")))
        assertNull(CustomEmoji.fromTag(listOf("emoji", "", "https://x.example/p.png")))
        assertNull(CustomEmoji.fromTag(listOf("emoji", "pepe", "javascript:alert(1)")))
        assertNull(CustomEmoji.fromTag(listOf("emoji", "pepe", "data:image/png;base64,AAAA")))
        assertNull(CustomEmoji.fromTag(listOf("emoji", "pepe", "file:///sdcard/p.png")))
        assertNull(CustomEmoji.fromTag(listOf("emoji", "pepe", "https://")))
        assertNull(CustomEmoji.fromTag(listOf("emoji", "pepe")))
        assertNull(CustomEmoji.fromTag(listOf("t", "pepe", "https://x.example/p.png")))
        // A 4th element that isn't a set address is ignored, not trusted.
        assertNull(CustomEmoji.fromTag(listOf("emoji", "pepe", "https://x.example/p.png", "junk"))!!.setAddress)
    }

    @Test
    fun `a shortcode tagged twice keeps the first image`() {
        val emojis = CustomEmoji.fromTags(
            listOf(
                listOf("emoji", "pepe", "https://first.example/p.png"),
                listOf("emoji", "pepe", "https://second.example/p.png"),
                listOf("emoji", "cat", "https://x.example/c.png"),
            ),
        )
        assertEquals(listOf("pepe", "cat"), emojis.keys.toList())
        assertEquals("https://first.example/p.png", emojis["pepe"]!!.url)
    }

    @Test
    fun `a reaction is custom only as a lone tagged shortcode`() {
        val tags = listOf(listOf("e", "abc"), listOf("emoji", "pepe", "https://x.example/p.png"))
        assertEquals("pepe", CustomEmoji.forReaction(":pepe:", tags)!!.shortcode)
        assertEquals("pepe", CustomEmoji.forReaction(" :pepe: ", tags)!!.shortcode)
        assertNull(CustomEmoji.forReaction(":cat:", tags))
        assertNull(CustomEmoji.forReaction("+", tags))
        assertNull(CustomEmoji.forReaction("🔥", tags))
        assertNull(CustomEmoji.forReaction("I :pepe:", tags))
    }

    @Test
    fun `text splits around shortcodes that have images`() {
        val emojis = mapOf("pepe" to CustomEmoji("pepe", "https://x.example/p.png"))
        assertEquals(
            listOf(
                CustomEmoji.Segment.Text("gm "),
                CustomEmoji.Segment.Emoji(emojis.getValue("pepe")),
                CustomEmoji.Segment.Text(" and :cat: 12:30"),
            ),
            CustomEmoji.segments("gm :pepe: and :cat: 12:30", emojis),
        )
        assertEquals(
            listOf(CustomEmoji.Segment.Emoji(emojis.getValue("pepe")), CustomEmoji.Segment.Emoji(emojis.getValue("pepe"))),
            CustomEmoji.segments(":pepe::pepe:", emojis),
        )
        assertEquals(listOf(CustomEmoji.Segment.Text("no tags :pepe:")), CustomEmoji.segments("no tags :pepe:", emptyMap()))
    }

    @Test
    fun `its tag round trips`() {
        val emoji = CustomEmoji("pepe", "https://x.example/p.png", set)
        assertEquals(emoji, CustomEmoji.fromTag(emoji.tag()))
        assertEquals(listOf("emoji", "pepe", "https://x.example/p.png"), CustomEmoji("pepe", "https://x.example/p.png").tag())
        assertEquals(":pepe:", emoji.content)
    }
}
