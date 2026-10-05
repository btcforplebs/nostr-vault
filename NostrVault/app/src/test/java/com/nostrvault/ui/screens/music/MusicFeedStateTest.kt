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
