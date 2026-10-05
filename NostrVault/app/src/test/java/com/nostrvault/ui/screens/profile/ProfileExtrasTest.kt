package com.nostrvault.ui.screens.profile

import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.Reel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ProfileExtrasTest {
    private val pk = "b".repeat(64)

    private fun note(id: String, kind: Int, seconds: Long, d: String, extra: List<List<String>> = emptyList()) =
        FeedNote.fromEvent(id, pk, "", listOf(listOf("d", d)) + extra, seconds, kind)

    @Test fun articlesKeepTheNewestVersionOfEachNewestFirst() {
        val old = note("a1", 30023, 100, "post")
        val edited = note("a2", 30023, 300, "post")
        val other = note("b1", 30023, 200, "other")
        val clip = note("v1", 34236, 400, "clip")
        assertEquals(listOf("a2", "b1"), ProfileExtras.articles(listOf(old, other, edited, clip)).map { it.id })
    }

    @Test fun reelsNeedAVideoAndOneTilePerFile() {
        val url = listOf("imeta", "url https://cdn.example/v.mp4", "m video/mp4", "image https://cdn.example/p.jpg")
        val a = note("v1", 34236, 100, "one", listOf(url))
        val sameFile = note("v2", 34236, 200, "two", listOf(url))
        val noVideo = note("v3", 34236, 300, "three")
        val reels = ProfileExtras.reels(listOf(a, sameFile, noVideo))
        assertEquals(listOf("v2"), reels.map { it.id })
        assertEquals("https://cdn.example/p.jpg", reels.single().posterUrl)
    }

    @Test fun relaysIncludeDivineAndDropDuplicates() {
        val relays = ProfileExtras.relays(
            ownRelay = "ws://127.0.0.1:3355",
            feedRelays = listOf("wss://a", "wss://b", "wss://c", "wss://d"),
            outbox = listOf("wss://a", "wss://e"),
        )
        assertEquals(listOf("ws://127.0.0.1:3355", "wss://a", "wss://b", "wss://c", "wss://e", Reel.DIVINE_RELAY), relays)
        assertEquals(Reel.DIVINE_RELAY, ProfileExtras.relays(null, emptyList(), emptyList()).last())
    }
}

class ProfileTabFillerTest {
    private fun item(index: Int, offset: Int, size: Int) = ProfileTabFiller.Item(index, offset, size)

    @Test fun shortSectionIsFilledToAScreen() {
        // Tabs at index 4 pinned at the top; one 100px item after them.
        val needed = ProfileTabFiller.needed(
            items = listOf(item(4, 0, 40), item(5, 40, 100)),
            firstSectionIndex = 5, fillerIndex = 6, visibleHeight = 800, bottomEdge = 800,
        )
        assertEquals(700, needed)
    }

    @Test fun longSectionNeedsNoFiller() {
        val items = (5..12).map { item(it, 40 + (it - 5) * 120, 120) }
        assertEquals(0, ProfileTabFiller.needed(items, 5, 13, visibleHeight = 800, bottomEdge = 800))
    }

    @Test fun sectionRunningOffScreenKeepsTheCurrentHeight() {
        val items = listOf(item(4, 0, 40), item(5, 40, 500), item(6, 540, 500))
        assertNull(ProfileTabFiller.needed(items, 5, 8, visibleHeight = 800, bottomEdge = 800))
    }

    @Test fun sectionScrolledPastItsTopFillsOnlyToTheBottomEdge() {
        val items = listOf(item(6, -50, 300))
        assertEquals(550, ProfileTabFiller.needed(items, 5, 7, visibleHeight = 800, bottomEdge = 800))
    }

    @Test fun emptySectionIsAScreenTall() {
        assertEquals(800, ProfileTabFiller.needed(emptyList(), 5, 5, visibleHeight = 800, bottomEdge = 800))
    }
}
