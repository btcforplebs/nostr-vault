package com.nostrvault.ui.components

import com.nostrvault.ui.components.ReactionChoice.Change
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Tap and hold on the reaction button (iOS #322). */
class ReactionChoiceTest {
    @Test
    fun tapReactsWithTheDefaultThenTakesItBack() {
        assertEquals(Change.React("+"), ReactionChoice.forTap(isLiked = false, defaultContent = "+"))
        assertEquals(Change.Remove, ReactionChoice.forTap(isLiked = true, defaultContent = "+"))
    }

    @Test
    fun buttonShowsTheEmojiThatWasSent() {
        assertNull(ReactionChoice.shown(isLiked = false, myContent = "🔥"))
        assertEquals("🔥", ReactionChoice.shown(isLiked = true, myContent = "🔥"))
        // A plain like, or one saved before the emoji was kept, is the heart.
        assertEquals("❤️", ReactionChoice.shown(isLiked = true, myContent = "+"))
        assertEquals("❤️", ReactionChoice.shown(isLiked = true, myContent = null))
    }

    @Test
    fun pickingAnotherEmojiSwapsIt() {
        assertEquals(Change.React("🔥"), ReactionChoice.forPick(isLiked = true, myContent = "+", picked = "🔥"))
        assertEquals(Change.React("🔥"), ReactionChoice.forPick(isLiked = false, myContent = null, picked = "🔥"))
    }

    @Test
    fun pickingTheSentEmojiTakesItBack() {
        assertEquals(Change.Remove, ReactionChoice.forPick(isLiked = true, myContent = "🔥", picked = "🔥"))
        // "+" shows as the heart, so the heart is the one already sent.
        assertEquals(Change.Remove, ReactionChoice.forPick(isLiked = true, myContent = "+", picked = "❤️"))
    }

    @Test
    fun barAlwaysOffersTheDefaultReaction() {
        assertEquals(ReactionChoice.TAPBACK, ReactionChoice.tapbackOptions("+"))
        assertEquals(ReactionChoice.TAPBACK, ReactionChoice.tapbackOptions("🔥"))
        val custom = ReactionChoice.tapbackOptions("🍕")
        assertEquals(6, custom.size)
        assertEquals("🍕", custom.first())
        assertEquals(ReactionChoice.TAPBACK.dropLast(1), custom.drop(1))
    }

    @Test
    fun slotUnderTheFinger() {
        // Bar at x=100, 6 px inset, 44 px slots, six emoji then "+".
        assertEquals(0, ReactionChoice.slotAt(107f, 100f, 6f, 44f, 6))
        assertEquals(2, ReactionChoice.slotAt(100f + 6f + 44f * 2 + 1f, 100f, 6f, 44f, 6))
        assertEquals(6, ReactionChoice.slotAt(100f + 6f + 44f * 6 + 10f, 100f, 6f, 44f, 6))
        // Past either end it stays on the end slots.
        assertEquals(0, ReactionChoice.slotAt(50f, 100f, 6f, 44f, 6))
        assertEquals(6, ReactionChoice.slotAt(2_000f, 100f, 6f, 44f, 6))
    }
}
