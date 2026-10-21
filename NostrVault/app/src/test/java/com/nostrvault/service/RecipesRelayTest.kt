package com.nostrvault.service

import com.nostrvault.data.model.FeedMode
import org.junit.Assert.assertEquals
import org.junit.Test

/** The Recipes tab asks zap.cooking's feed relay on top of the user's own (Logen, 2026-10-17). */
class RecipesRelayTest {

    private val mine = listOf("wss://relay.damus.io", "wss://relay.primal.net")

    @Test
    fun `recipes adds feed zap cooking`() {
        assertEquals(mine + "wss://feed.zap.cooking", FeedService.relaysForMode(FeedMode.RECIPES, mine))
    }

    @Test
    fun `recipes still has a relay when the user has none`() {
        assertEquals(listOf("wss://feed.zap.cooking"), FeedService.relaysForMode(FeedMode.RECIPES, emptyList()))
    }

    @Test
    fun `recipes does not list it twice`() {
        val withIt = mine + "wss://feed.zap.cooking"
        assertEquals(withIt, FeedService.relaysForMode(FeedMode.RECIPES, withIt))
    }

    @Test
    fun `other feeds keep the user's relays only`() {
        for (mode in FeedMode.entries.filter { it != FeedMode.RECIPES }) {
            assertEquals(mine, FeedService.relaysForMode(mode, mine))
        }
    }
}
