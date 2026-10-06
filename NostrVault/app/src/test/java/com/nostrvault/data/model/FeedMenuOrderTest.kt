package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Test

/** Ports of iOS FeedLayoutModeTests' feed picker order cases (#303). */
class FeedMenuOrderTest {
    private val defaults = listOf("following", "global", "popular", "media", "music")

    @Test
    fun noStoredOrderIsTheDefault() {
        assertEquals(defaults, FeedMenuOrder.visible(emptyList(), emptyList(), defaults, "following"))
    }

    @Test
    fun storedOrderAndHiddenAreApplied() {
        val shown = FeedMenuOrder.visible(
            listOf("media", "following", "global", "popular", "music"),
            listOf("popular"), defaults, "following",
        )
        assertEquals(listOf("media", "following", "global", "music"), shown)
    }

    @Test
    fun theHomeFeedCannotBeHidden() {
        val shown = FeedMenuOrder.visible(emptyList(), listOf("following", "global"), defaults, "following")
        assertEquals(listOf("following", "popular", "media", "music"), shown)
    }

    @Test
    fun newFeedsSlotInAndRemovedOnesDrop() {
        // "music" is new since the order was saved, so it goes in after
        // "media", the feed before it by default. "recipes" no longer exists.
        val shown = FeedMenuOrder.ordered(listOf("media", "recipes", "following", "global", "popular"), defaults)
        assertEquals(listOf("media", "music", "following", "global", "popular"), shown)
    }

    @Test
    fun aNewFirstFeedGoesFirst() {
        assertEquals(defaults, FeedMenuOrder.ordered(listOf("global", "popular", "media", "music"), defaults))
    }

    @Test
    fun duplicatesAreDropped() {
        assertEquals(defaults, FeedMenuOrder.ordered(listOf("following", "following", "global", "popular", "media", "music"), defaults))
    }

    @Test
    fun encodeRoundTrips() {
        assertEquals(defaults, FeedMenuOrder.decode(FeedMenuOrder.encode(defaults)))
        assertEquals(emptyList<String>(), FeedMenuOrder.decode(""))
    }

    @Test
    fun everyAndroidFeedIsListedByDefault() {
        assertEquals(FeedMode.entries.map { it.name }, FeedMenuOrder.ordered(emptyList(), FeedMode.entries.map { it.name }))
    }

    @Test
    fun hashtagsJoinsASavedOrderAfterGlobal() {
        // An order saved before Hashtags existed, rearranged and with Global moved down.
        val saved = FeedMode.entries.filter { it != FeedMode.HASHTAGS }.map { it.name }
            .let { listOf("POPULAR", "FOLLOWING") + (it - setOf("POPULAR", "FOLLOWING")) }
        val ordered = FeedMenuOrder.ordered(saved, FeedMode.entries.map { it.name })
        assertEquals(FeedMode.entries.size, ordered.size)
        assertEquals(ordered.indexOf("GLOBAL") + 1, ordered.indexOf("HASHTAGS"))
        // Hideable like any non-home feed.
        val shown = FeedMenuOrder.visible(saved, listOf("HASHTAGS"), FeedMode.entries.map { it.name }, "FOLLOWING")
        assertEquals(false, "HASHTAGS" in shown)
    }
}
