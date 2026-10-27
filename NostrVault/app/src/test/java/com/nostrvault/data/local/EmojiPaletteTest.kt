package com.nostrvault.data.local

import org.junit.Assert.assertEquals
import org.junit.Test

class EmojiPaletteTest {
    private val pepe = ReactionPick(":pepe:", "pepe", "https://x.example/p.png")
    private fun u(e: String) = ReactionPick(e)

    @Test
    fun `recents are newest first, once each, capped`() {
        var state = EmojiPalette.State()
        for (e in listOf("🔥", "😂", "🔥")) state = EmojiPalette.recordUse(state, u(e))
        state = EmojiPalette.recordUse(state, pepe)
        assertEquals(listOf(":pepe:", "🔥", "😂"), state.recents.map { it.content })
        repeat(40) { state = EmojiPalette.recordUse(state, u("x$it")) }
        assertEquals(EmojiPalette.RECENTS_MAX, state.recents.size)
        assertEquals("x39", state.recents.first().content)
    }

    @Test
    fun `the same shortcode with another image is another emoji`() {
        val other = ReactionPick(":pepe:", "pepe", "https://y.example/p.png")
        var state = EmojiPalette.recordUse(EmojiPalette.State(), pepe)
        state = EmojiPalette.recordUse(state, other)
        assertEquals(2, state.recents.size)
    }

    @Test
    fun `the bar orders itself by use, ties keep their place`() {
        var state = EmojiPalette.State()
        assertEquals(EmojiPalette.DEFAULT_BAR, EmojiPalette.orderedBar(state))
        repeat(2) { state = EmojiPalette.recordUse(state, u("😢")) }
        state = EmojiPalette.recordUse(state, u("🔥"))
        assertEquals(listOf("😢", "🔥", "❤️", "🤙", "😂", "😮"), EmojiPalette.orderedBar(state).map { it.content })
    }

    @Test
    fun `using an emoji off the bar does not change what is on it`() {
        val state = EmojiPalette.recordUse(EmojiPalette.State(), u("🍕"))
        assertEquals(EmojiPalette.DEFAULT_BAR.toSet(), EmojiPalette.orderedBar(state).toSet())
    }

    @Test
    fun `editing a slot puts the new emoji there, or swaps one already on the bar`() {
        var state = EmojiPalette.replaceSlot(EmojiPalette.State(), u("🤙"), pepe)
        assertEquals(listOf("❤️", ":pepe:", "🔥", "😂", "😮", "😢"), state.slots.map { it.content })
        state = EmojiPalette.replaceSlot(state, u("❤️"), u("😢"))
        assertEquals(listOf("😢", ":pepe:", "🔥", "😂", "😮", "❤️"), state.slots.map { it.content })
        // A slot that isn't on the bar changes nothing.
        assertEquals(state, EmojiPalette.replaceSlot(state, u("🍕"), u("🎉")))
    }

    @Test
    fun `a broken saved bar is made whole`() {
        val broken = EmojiPalette.State(slots = listOf(pepe, pepe, u("🔥")))
        assertEquals(listOf(":pepe:", "🔥", "❤️", "🤙", "😂", "😮"), EmojiPalette.normalized(broken).slots.map { it.content })
    }

    @Test
    fun `use counts stay bounded and keep the bar's`() {
        var state = EmojiPalette.State()
        repeat(EmojiPalette.COUNTS_MAX + 50) { state = EmojiPalette.recordUse(state, u("e$it")) }
        state = EmojiPalette.recordUse(state, u("❤️"))
        assert(state.counts.size <= EmojiPalette.COUNTS_MAX)
        assertEquals(1, state.counts["❤️"])
    }
}
