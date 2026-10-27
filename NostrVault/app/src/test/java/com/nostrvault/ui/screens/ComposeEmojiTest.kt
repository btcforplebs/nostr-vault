package com.nostrvault.ui.screens

import com.nostrvault.service.CustomEmoji
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ComposeEmojiTest {
    private val pepe = CustomEmoji("pepe", "https://x.example/pepe.png")
    private val pepeSleep = CustomEmoji("pepesleep", "https://x.example/sleep.gif")
    private val sleepy = CustomEmoji("sleepy_pepe", "https://x.example/sleepy.png")

    @Test
    fun `a colon starting a word with two letters is a query`() {
        assertEquals(ComposeEmoji.Query(3, 7, "pep"), ComposeEmoji.queryAt("gm :pep", 7))
        assertEquals(ComposeEmoji.Query(0, 3, "pe"), ComposeEmoji.queryAt(":pe", 3))
        // Mid-text, at the caret.
        assertEquals(ComposeEmoji.Query(0, 4, "pep"), ComposeEmoji.queryAt(":pep and more", 4))
    }

    @Test
    fun `times, links, short names and finished shortcodes are not queries`() {
        assertNull(ComposeEmoji.queryAt("at 12:30", 8))
        assertNull(ComposeEmoji.queryAt("https://x", 9))
        assertNull(ComposeEmoji.queryAt("hi :p", 5))
        assertNull(ComposeEmoji.queryAt("hi :", 4))
        assertNull(ComposeEmoji.queryAt("hi :pepe: ", 10))
        assertNull(ComposeEmoji.queryAt("hi :pe pe", 9))
    }

    @Test
    fun `suggestions put prefix matches first, once each, capped`() {
        val known = listOf(sleepy, pepe, pepeSleep, pepe)
        assertEquals(listOf(pepe, pepeSleep, sleepy), ComposeEmoji.suggestions("PEP", known))
        assertEquals(listOf(sleepy, pepeSleep), ComposeEmoji.suggestions("sle", known))
        val many = (1..20).map { CustomEmoji("e$it", "https://x.example/$it.png") }
        assertEquals(ComposeEmoji.MAX_SUGGESTIONS, ComposeEmoji.suggestions("e1", many + many.map { CustomEmoji("e1x${it.shortcode}", it.url) }).size)
    }

    @Test
    fun `picking a suggestion replaces the query with the shortcode`() {
        val q = ComposeEmoji.queryAt("gm :pep friends", 7)!!
        assertEquals("gm :pepe:  friends" to 10, ComposeEmoji.insert("gm :pep friends", q, pepe))
    }

    @Test
    fun `the emoji button inserts at the caret`() {
        assertEquals("gm :pepe: " to 10, ComposeEmoji.insertAt("gm", 2, ":pepe:"))
        assertEquals("gm 🔥x" to 5, ComposeEmoji.insertAt("gm x", 3, "🔥"))
        assertEquals(":pepe: hi" to 7, ComposeEmoji.insertAt("hi", 0, ":pepe:"))
    }

    @Test
    fun `a post tags each custom emoji it uses once, and nothing else`() {
        val known = mapOf("pepe" to pepe, "pepesleep" to pepeSleep)
        assertEquals(
            listOf(pepe.tag(), pepeSleep.tag()),
            ComposeEmoji.tags("gm :pepe: :pepesleep: :pepe: at 12:30 :unknown:", known),
        )
        assertEquals(emptyList<List<String>>(), ComposeEmoji.tags("no emoji here", known))
    }
}
