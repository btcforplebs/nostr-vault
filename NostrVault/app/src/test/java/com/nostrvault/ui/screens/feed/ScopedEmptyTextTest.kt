package com.nostrvault.ui.screens.feed

import com.nostrvault.data.model.FeedMode
import com.nostrvault.service.LiveFeedService
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

    @Test
    fun liveEmptyStatesSayWhoWasAskedAndNeverBlameNostr() {
        val noFollows = scopedEmptyText(FeedMode.LIVE, true, liveFollowSetIsEmpty = true)!!
        assertEquals("You don't follow anyone yet. Global shows everyone who is streaming.", noFollows.subtitle)
        assertTrue(noFollows.showsGlobal)
        // Nothing was asked, so no relay failing to answer can be the reason.
        assertFalse(scopedEmptyText(FeedMode.LIVE, true, loadFailed = true, liveFollowSetIsEmpty = true)!!.noConnection)

        assertEquals("Nothing live right now",
            scopedEmptyText(FeedMode.LIVE, false, liveGate = LiveFeedService.GlobalGate.NewAccount)!!.title)
        assertEquals("Nobody in your network is live",
            scopedEmptyText(FeedMode.LIVE, false, liveGate = LiveFeedService.GlobalGate.Trusted(setOf("a")))!!.title)
        assertEquals("Building your web of trust",
            scopedEmptyText(FeedMode.LIVE, false, liveGate = LiveFeedService.GlobalGate.Trusted(emptySet()))!!.title)

        val gates = listOf(null, LiveFeedService.GlobalGate.Everyone, LiveFeedService.GlobalGate.NewAccount,
            LiveFeedService.GlobalGate.Trusted(emptySet()), LiveFeedService.GlobalGate.Trusted(setOf("a")))
        for (following in listOf(true, false)) for (gate in gates) {
            val text = scopedEmptyText(FeedMode.LIVE, following, liveGate = gate)!!
            assertFalse(text.subtitle, "Nostr" in text.subtitle)
        }
    }
}
