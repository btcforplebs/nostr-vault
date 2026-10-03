package com.nostrvault.data.music

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Payload shapes captured from wavlake.com/api/v1/content on 2026-10-02. Same cases as iOS WavlakeTests. */
class WavlakeTest {
    @Test fun rankingsKeepOnlyPlayableTracks() {
        val body = """[{"id":"ba8926a3","title":"Not In Yer Wallet","albumArtUrl":"https://x/c.jpg","artistId":"9a55","albumId":"c6b5","albumTitle":"Sound Money","mediaUrl":"https://op3.dev/e,pg=6a99/https://d1/track/ba89.mp3","artist":"Rare Scrilla","msatTotal":"5000000","duration":149},
            {"id":"nomedia","title":"Broken","artist":"X"},
            {"id":"badscheme","title":"Odd","artist":"X","mediaUrl":"ftp://example.com/a.mp3"}]"""
        val tracks = WavlakeApi.tracksFromRankings(body)
        assertEquals(listOf("ba8926a3"), tracks.map { it.id })
        val t = tracks[0]
        assertEquals("Rare Scrilla", t.artist)
        assertEquals(149, t.duration)
        assertEquals(5000L, t.sats)
        assertEquals("https://wavlake.com/track/ba8926a3", t.pageUrl)
    }

    @Test fun searchSplitsTracksAlbumsArtists() {
        val body = """[{"id":"a1","name":"Bitcoin Block Jams","type":"artist","artistArtUrl":"https://x/a.jpg"},
            {"id":"al1","name":"Paper Bitcoin","type":"album","albumArtUrl":"https://x/b.jpg"},
            {"id":"t1","name":"Bitcoin Beach","type":"track","artist":"Someone","mediaUrl":"https://x/t1.mp3"},
            {"id":"t2","name":"No audio","type":"track"},
            {"id":"p1","name":"A podcast","type":"podcast"}]"""
        assertEquals(listOf("artist:a1", "album:al1", "track:t1"), WavlakeApi.resultsFromSearch(body).map { it.key })
    }

    @Test fun albumTracksBorrowTheAlbumArtist() {
        val body = """{"id":"al","artist":"Rare Scrilla","tracks":[{"id":"t1","title":"21 Million","mediaUrl":"https://x/1.mp3","duration":200.0},{"id":"t2","title":"Own","artist":"Guest","mediaUrl":"https://x/2.mp3"}]}"""
        val tracks = WavlakeApi.tracksFromAlbum(body)
        assertEquals(listOf("Rare Scrilla", "Guest"), tracks.map { it.artist })
        assertEquals(200, tracks[0].duration)
    }

    @Test fun artistAlbumIds() {
        assertEquals(listOf("x", "y"), WavlakeApi.albumIdsFromArtist("""{"albums":[{"id":"x"},{"id":"y"},{"title":"none"}]}"""))
    }

    @Test fun garbageIsEmpty() {
        assertTrue(WavlakeApi.tracksFromRankings("<html>").isEmpty())
        assertTrue(WavlakeApi.resultsFromSearch("{}").isEmpty())
        assertTrue(WavlakeApi.tracksFromAlbum("[]").isEmpty())
    }

    @Test fun artistNpubOnlyWhenNpub() {
        val body = """[{"id":"t","title":"S","artist":"A","mediaUrl":"https://x/a.mp3","artistNpub":"npub1abc"},{"id":"u","title":"S","artist":"A","mediaUrl":"https://x/b.mp3","artistNpub":""}]"""
        assertEquals(listOf("npub1abc", null), WavlakeApi.tracksFromRankings(body).map { it.artistNpub })
    }

    @Test fun trackIdFromLinks() {
        val id = "ba8926a3-02bc-4b1d-b9f2-2a79e851121b"
        assertEquals(id, WavlakeLink.trackId("https://wavlake.com/track/$id"))
        assertEquals(id, WavlakeLink.trackId("https://embed.wavlake.com/track/${id.uppercase()}"))
        assertNull(WavlakeLink.trackId("https://wavlake.com/album/$id"))
        assertNull(WavlakeLink.trackId("https://wavlake.com/track/not-a-uuid"))
        assertNull(WavlakeLink.trackId("https://notwavlake.com/track/$id"))
        assertNull(WavlakeLink.trackId("https://evil.com/wavlake.com/track/$id"))
    }

    @Test fun shareTextMentionsArtistOnNostr() {
        val t = WavlakeTrack(id = "t1", title = "21 Million", artist = "Rare Scrilla", mediaUrl = "https://x/a.mp3", artistNpub = "npub1xyz")
        assertEquals("🎵 21 Million by nostr:npub1xyz\n\nhttps://wavlake.com/track/t1", WavlakeLink.shareText(t))
    }

    @Test fun searchUrlEscapes() {
        assertEquals("https://wavlake.com/api/v1/content/search?term=rock%20%26%20roll", WavlakeApi.searchUrl("rock & roll"))
    }
}
