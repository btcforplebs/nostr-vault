package com.nostrvault.ui.screens.feed

import com.nostrvault.data.model.FeedMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** iOS's Recipes / Marketplace / Live empty states, on Android. */
class ScopedEmptyTextTest {
    @Test
    fun followingOffersGlobal() {
        for ((mode, action) in listOf(
            FeedMode.RECIPES to "Show Global recipes",
            FeedMode.MARKETPLACE to "Show Global listings",
            FeedMode.LIVE to "Show Global streams",
        )) {
            val text = scopedEmptyText(mode, scopeFollowing = true)!!
            assertEquals(action, text.action)
            assertTrue(text.showsGlobal)
        }
    }

    @Test
    fun globalOffersTryAgain() {
        for (mode in listOf(FeedMode.RECIPES, FeedMode.MARKETPLACE, FeedMode.LIVE)) {
            val text = scopedEmptyText(mode, scopeFollowing = false)!!
            assertEquals("Try again", text.action)
            assertFalse(text.showsGlobal)
        }
        assertEquals("Nothing live right now", scopedEmptyText(FeedMode.LIVE, false)!!.title)
    }

    @Test
    fun otherFeedsKeepTheirOwnPlaceholder() {
        assertNull(scopedEmptyText(FeedMode.FOLLOWING, true))
        assertNull(scopedEmptyText(FeedMode.ARTICLES, true))
    }
}
