package com.nostrvault.widget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WidgetConfigTest {

    private fun lookup(map: Map<String, String>): (String) -> String? = { map[it] }

    @Test
    fun unconfiguredWidgetsGetTheIosDefaults() {
        val none = lookup(emptyMap())
        assertEquals(
            listOf(QuickAction.COMPOSE, QuickAction.DMS, QuickAction.SEARCH, QuickAction.RELAY),
            QuickActionsConfig.from(none).slots,
        )
        assertEquals(FeedConfig(FeedSource.FOLLOWING, FeedDensity.COMFORTABLE, showAvatars = true), FeedConfig.from(none))
        assertEquals(MosaicConfig(MosaicStyle.GRID, rounded = true), MosaicConfig.from(none))
    }

    @Test
    fun configsRoundTripThroughTheirEntries() {
        val qa = QuickActionsConfig(listOf(QuickAction.WALLET, QuickAction.MEDIA, QuickAction.WALLET, QuickAction.DMS))
        assertEquals(qa, QuickActionsConfig.from(lookup(qa.toEntries())))
        val feed = FeedConfig(FeedSource.MENTIONS, FeedDensity.COMPACT, showAvatars = false)
        assertEquals(feed, FeedConfig.from(lookup(feed.toEntries())))
        val mosaic = MosaicConfig(MosaicStyle.FEATURED, rounded = false)
        assertEquals(mosaic, MosaicConfig.from(lookup(mosaic.toEntries())))
    }

    @Test
    fun oneBadSlotFallsBackAloneWithoutResettingTheOthers() {
        val slots = QuickActionsConfig.from(
            lookup(mapOf("qa.slot0" to "WALLET", "qa.slot1" to "RETIRED_ACTION", "qa.slot3" to "MEDIA"))
        ).slots
        assertEquals(listOf(QuickAction.WALLET, QuickAction.DMS, QuickAction.SEARCH, QuickAction.MEDIA), slots)
    }

    @Test
    fun garbageBooleansFallBackToDefaults() {
        val feed = FeedConfig.from(lookup(mapOf(FeedConfig.AVATARS to "yes")))
        assertEquals(true, feed.showAvatars)
        assertFalse(FeedConfig.from(lookup(mapOf(FeedConfig.AVATARS to "false"))).showAvatars)
    }

    @Test
    fun compactIsOneBodyLine() {
        assertEquals(1, FeedDensity.COMPACT.bodyLines)
        assertEquals(2, FeedDensity.COMFORTABLE.bodyLines)
    }

    @Test
    fun everyQuickActionHasARoutedDestination() {
        val routed = setOf("compose", "dms", "search", "relay", "media", "wallet")
        QuickAction.entries.forEach { assertTrue(it.name, it.destination in routed) }
    }

    @Test
    fun featuredStripOnlyWhenThereIsRoom() {
        assertEquals(0, MosaicGrid.featuredStripCount(140f, 140f, 44f, 4f))
        assertEquals(0, MosaicGrid.featuredStripCount(330f, 120f, 44f, 4f))
        assertEquals(6, MosaicGrid.featuredStripCount(300f, 300f, 44f, 4f))
    }
}
