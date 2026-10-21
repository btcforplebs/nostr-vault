package com.nostrvault.ui.screens.feed

import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.music.WavlakeArtist
import com.nostrvault.ui.screens.addTileLabel
import com.nostrvault.ui.screens.music.MusicScope
import com.nostrvault.ui.screens.music.TrendingWindow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Feed top bar and Sell form rules matched to iOS. */
class FeedChromeIosParityTest {

    @Test fun `layout button only on note timelines`() {
        listOf(FeedMode.REELS, FeedMode.MARKETPLACE, FeedMode.LIVE, FeedMode.MUSIC, FeedMode.ARTICLES)
            .forEach { assertFalse(it.name, it.hasLayoutButton) }
        listOf(FeedMode.FOLLOWING, FeedMode.GLOBAL, FeedMode.DISCOVERY)
            .forEach { assertTrue(it.name, it.hasLayoutButton) }
    }

    @Test fun `music scope note says what iOS says`() {
        assertEquals("Trending this week", musicScopeNoteSetting(MusicScope.Trending, TrendingWindow.WEEK))
        assertEquals("Trending this month", musicScopeNoteSetting(MusicScope.Trending, TrendingWindow.MONTH))
        assertEquals("Artists you follow", musicScopeNoteSetting(MusicScope.Following, TrendingWindow.WEEK))
        val artist = WavlakeArtist(id = "a1", name = "Ainsley Costello")
        assertEquals("Ainsley Costello", musicScopeNoteSetting(MusicScope.Artist(artist), TrendingWindow.WEEK))
    }

    @Test fun `sell add tile says Add once a photo is picked`() {
        assertEquals("Add photos", addTileLabel(0))
        assertEquals("Add", addTileLabel(1))
    }
}
