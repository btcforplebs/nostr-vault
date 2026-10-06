package com.nostrvault.data.local

import com.nostrvault.data.local.EngagementTracker.MyReaction
import com.nostrvault.data.local.EngagementTracker.ReactionEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The account's own reactions: which emoji it sent, that a removed one stays
 * removed when relays keep serving it, and the deletion that removes it
 * (iOS MyReactionTests, #322).
 */
class MyReactionTest {
    private val owner = "owner"
    private val mine = ReactionEvent(targetId = "note1", pubkey = "owner", eventId = "rx1", content = "🔥")
    private val theirs = ReactionEvent(targetId = "note1", pubkey = "someone", eventId = "rx2", content = "+")

    @Test
    fun ownReactionKeepsItsContentAndEvent() {
        val found = EngagementTracker.detectSelfReactions(listOf(mine, theirs), owner, retracted = emptySet())
        assertEquals(mapOf("note1" to MyReaction("🔥", "rx1")), found)
    }

    @Test
    fun noAccountFindsNothing() {
        assertTrue(EngagementTracker.detectSelfReactions(listOf(mine), ownerHex = "", retracted = emptySet()).isEmpty())
    }

    @Test
    fun retractedReactionIsNotTheAccountsAnymore() {
        assertTrue(EngagementTracker.detectSelfReactions(listOf(mine), owner, retracted = setOf("rx1")).isEmpty())
    }

    @Test
    fun retractedReactionIsNotCounted() {
        val stats = EngagementTracker.mergeEngagementCounts(
            listOf(mine, theirs), repostTargets = emptyList(), currentStats = emptyMap(), retracted = setOf("rx1"),
        )
        assertEquals(1, stats["note1"]?.reactionCount)
    }

    @Test
    fun removalPublishesADeletionOfTheReaction() {
        assertEquals(listOf(listOf("e", "rx1"), listOf("k", "7")), EngagementTracker.reactionDeletionTags("rx1"))
    }

    @Test
    fun stateRoundTripsReactions() {
        val saved = EngagementTracker.InteractionState(
            likedEventIds = setOf("note1"),
            zappedEventIds = emptyMap(),
            myReactions = mapOf("note1" to MyReaction("🔥", "rx1")),
            retractedReactionIds = setOf("rx0"),
        )
        val state = EngagementTracker.decodeInteractionState(EngagementTracker.encodeInteractionState(saved))!!
        assertEquals(MyReaction("🔥", "rx1"), state.myReactions["note1"])
        assertEquals(setOf("rx0"), state.retractedReactionIds)
    }

    /** Files saved before reactions were kept still load, with none. */
    @Test
    fun olderFileLoadsWithoutReactions() {
        val state = EngagementTracker.decodeInteractionState("""{"likedEventIds":["a"],"zappedEventIds":{}}""")!!
        assertEquals(setOf("a"), state.likedEventIds)
        assertTrue(state.myReactions.isEmpty())
        assertTrue(state.retractedReactionIds.isEmpty())
    }

    /** A reaction still being signed has no event id yet. */
    @Test
    fun signingReactionRoundTripsWithoutAnId() {
        val saved = EngagementTracker.InteractionState(setOf("n"), emptyMap(), myReactions = mapOf("n" to MyReaction("+")))
        val state = EngagementTracker.decodeInteractionState(EngagementTracker.encodeInteractionState(saved))!!
        assertEquals(MyReaction("+", null), state.myReactions["n"])
    }
}
