package com.nostrvault.ui.screens.feed

import com.nostrvault.data.model.FeedMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** iOS's scoped empty states (Recipes, Marketplace, Live, Articles, Media), on Android. */
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
    fun noRelayAnsweringSaysSoInEitherScope() {
        for ((mode, noun) in listOf(
            FeedMode.RECIPES to "Recipes",
            FeedMode.MARKETPLACE to "Listings",
            FeedMode.LIVE to "Live streams",
        )) {
            for (following in listOf(true, false)) {
                val text = scopedEmptyText(mode, following, loadFailed = true)!!
                assertEquals("Could not reach any relay", text.title)
                assertEquals("$noun come from other people's relays, so this one needs a connection.", text.subtitle)
                assertEquals("Try again", text.action)
                assertTrue(text.noConnection)
            }
        }
    }

    @Test
    fun articlesAndMediaNameTheScopeWithNoButton() {
        val following = scopedEmptyText(FeedMode.ARTICLES, true)!!
        assertEquals("No articles yet", following.title)
        assertEquals("Long-form posts from people you follow show up here. Nothing to read yet.", following.subtitle)
        assertNull(following.action)
        assertEquals(
            "Long-form posts from across Nostr show up here. Nothing to read yet.",
            scopedEmptyText(FeedMode.ARTICLES, false)!!.subtitle,
        )
        assertEquals("No global media found on connected relays.", scopedEmptyText(FeedMode.MEDIA, false)!!.subtitle)
        assertNull(scopedEmptyText(FeedMode.MEDIA, true)!!.action)
        // Articles come from your own relay too, so a failed load is not theirs to report.
        assertFalse(scopedEmptyText(FeedMode.ARTICLES, false, loadFailed = true)!!.noConnection)
    }

    @Test
    fun otherFeedsKeepTheirOwnPlaceholder() {
        assertNull(scopedEmptyText(FeedMode.FOLLOWING, true))
        assertNull(scopedEmptyText(FeedMode.POPULAR, false))
    }
}
