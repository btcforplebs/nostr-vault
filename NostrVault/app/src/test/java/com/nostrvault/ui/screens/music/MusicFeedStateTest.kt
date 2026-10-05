package com.nostrvault.ui.screens.music

import com.nostrvault.data.music.WavlakeAlbum
import com.nostrvault.data.music.WavlakeArtist
import com.nostrvault.data.music.WavlakeTrack
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MusicFeedStateTest {
    private val track = WavlakeTrack(
        id = "t1", title = "21 Million", artist = "Rare Scrilla", artistId = "a1",
        albumId = "al1", albumTitle = "Sound Money", albumArtUrl = "https://x/c.jpg",
        mediaUrl = "https://x/a.mp3", artistNpub = "npub1x", artistArtUrl = "https://x/p.jpg",
    )

    @After fun reset() {
        MusicFeedState.closePages()
        MusicFeedState.consumeReveal()
        MusicFeedState.isVisible = false
    }

    @Test fun pagesForASong() {
        assertEquals(
            MusicPage.Artist(WavlakeArtist("a1", "Rare Scrilla", "https://x/p.jpg", "npub1x")),
            MusicPage.artistOf(track),
        )
        assertEquals(
            MusicPage.Album(WavlakeAlbum("al1", "Sound Money", "https://x/c.jpg", "Rare Scrilla", "a1")),
            MusicPage.albumOf(track),
        )
        assertNull(MusicPage.artistOf(track.copy(artistId = null)))
        assertNull(MusicPage.albumOf(track.copy(albumId = null)))
    }

    @Test fun openStacksAndBackPops() {
        val artist = MusicPage.artistOf(track)!!
        val album = MusicPage.albumOf(track)!!
        MusicFeedState.open(artist)
        MusicFeedState.open(artist) // the page already showing isn't stacked twice
        MusicFeedState.open(album)
        assertEquals(listOf(artist, album), MusicFeedState.path.value)
        MusicFeedState.goBack()
        assertEquals(listOf(artist), MusicFeedState.path.value)
    }

    @Test fun revealOffTheMusicFeedAsksForIt() {
        val album = MusicPage.albumOf(track)!!
        MusicFeedState.open(MusicPage.artistOf(track)!!)
        MusicFeedState.reveal(album)
        assertEquals(listOf(album), MusicFeedState.path.value)
        assertTrue(MusicFeedState.revealRequested.value)
        // Not showing, so no "Go to" is hidden.
        assertNull(MusicFeedState.showingAlbumId)
    }

    @Test fun revealOnTheMusicFeedOpensOnTop() {
        MusicFeedState.isVisible = true
        val artist = MusicPage.artistOf(track)!!
        MusicFeedState.reveal(artist)
        assertFalse(MusicFeedState.revealRequested.value)
        assertEquals("a1", MusicFeedState.showingArtistId)
    }

    @Test fun counts() {
        assertEquals("1 song", MusicCount.songs(1))
        assertEquals("3 albums", MusicCount.albums(3))
        assertEquals("1 min", MusicCount.minutes(10))
        assertEquals("1 hr 5 min", MusicCount.minutes(3900))
    }
}

class MusicFeedRowsTest {
    private fun t(id: String, artistId: String?, albumId: String?) = WavlakeTrack(
        id = id, title = id, artist = "Artist $artistId", artistId = artistId,
        albumId = albumId, albumTitle = albumId?.let { "Album $it" }, mediaUrl = "https://x/$id.mp3",
    )

    @Test fun trendingRowsKeepFirstPlaceOnce() {
        val tracks = listOf(t("1", "a", "x"), t("2", "b", "y"), t("3", "a", "x"), t("4", null, null), t("5", "c", "z"))
        assertEquals(listOf("a", "b", "c"), MusicTrendingRows.artists(tracks).map { it.id })
        assertEquals(listOf("x", "y", "z"), MusicTrendingRows.albums(tracks).map { it.id })
        val many = (1..40).map { t("$it", "a$it", "al$it") }
        assertEquals(MusicTrendingRows.ROW_LIMIT, MusicTrendingRows.artists(many).size)
    }

    @Test fun recentArtistsNewestFirstKeepKnownArtAndKey() {
        val a = WavlakeArtist("a", "A", artUrl = "https://x/a.jpg", npub = "npub1a")
        val b = WavlakeArtist("b", "B")
        var list = MusicRecentArtists.add(emptyList(), a, 3)
        list = MusicRecentArtists.add(list, b, 3)
        list = MusicRecentArtists.add(list, WavlakeArtist("a", "A"), 3)
        assertEquals(listOf("a", "b"), list.map { it.id })
        assertEquals("https://x/a.jpg", list[0].artUrl)
        assertEquals("npub1a", list[0].npub)
        list = MusicRecentArtists.add(list, WavlakeArtist("c", "C"), 3)
        list = MusicRecentArtists.add(list, WavlakeArtist("d", "D"), 3)
        assertEquals(listOf("d", "c", "a"), list.map { it.id })
    }
}
