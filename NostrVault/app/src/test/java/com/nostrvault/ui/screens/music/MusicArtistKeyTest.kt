package com.nostrvault.ui.screens.music

import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.music.WavlakeArtist
import com.nostrvault.data.music.WavlakeTrack
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Music tray (iOS #1084): sharing a song mentions its artist, and the tray can zap them. */
class MusicArtistKeyTest {
    private val npub = "npub1artist"
    private fun song(npub: String? = null, artistId: String? = "a1") =
        WavlakeTrack(id = "t1", title = "Song", artist = "Band", artistId = artistId, mediaUrl = "https://x/t1.mp3", artistNpub = npub)

    @After fun reset() {
        MusicArtistKey.forget()
        MusicArtistKey.fetchArtist = { null }
        MusicArtistKey.knownArtists = { emptyList() }
        MusicArtistKey.shareWaitMs = 3_000L
    }

    @Test fun `the song's own key, then a known artist, then Wavlake once`() = runBlocking {
        var calls = 0
        MusicArtistKey.knownArtists = { emptyList() }
        MusicArtistKey.fetchArtist = { calls++; WavlakeArtist(id = it, name = "Band", npub = npub) }
        assertEquals("npub1own", MusicArtistKey.npub(song(npub = "npub1own")))
        assertEquals(0, calls)
        assertEquals(npub, MusicArtistKey.npub(song()))
        assertEquals(npub, MusicArtistKey.npub(song()))
        assertEquals("one Wavlake call per artist", 1, calls)

        MusicArtistKey.forget()
        MusicArtistKey.knownArtists = { listOf(WavlakeArtist(id = "a1", name = "Band", npub = "npub1known")) }
        assertEquals("npub1known", MusicArtistKey.npub(song()))
        assertEquals(1, calls)
    }

    @Test fun `no key is remembered too, and no artist id asks nobody`() = runBlocking {
        var calls = 0
        MusicArtistKey.fetchArtist = { calls++; WavlakeArtist(id = it, name = "Band", npub = null) }
        assertNull(MusicArtistKey.npub(song()))
        assertNull(MusicArtistKey.npub(song()))
        assertEquals(1, calls)
        assertNull(MusicArtistKey.npub(song(artistId = null)))
        assertEquals(1, calls)
    }

    /** The composer posts `nostr:npub…` with a `p` tag, so the share tags the artist. */
    @Test fun `share mentions the artist, or names them when Wavlake is slow`() = runBlocking {
        MusicArtistKey.fetchArtist = { WavlakeArtist(id = it, name = "Band", npub = npub) }
        assertEquals("🎵 Song by nostr:$npub\n\nhttps://wavlake.com/track/t1", MusicArtistKey.shareText(song()))

        MusicArtistKey.forget()
        MusicArtistKey.shareWaitMs = 50
        MusicArtistKey.fetchArtist = { delay(5_000); WavlakeArtist(id = it, name = "Band", npub = npub) }
        assertEquals("🎵 Song by Band\n\nhttps://wavlake.com/track/t1", MusicArtistKey.shareText(song()))
    }

    @Test fun `zap needs a lightning address`() {
        assertFalse(takesZaps(null))
        assertFalse(takesZaps(FeedProfile(pubkey = "p")))
        assertTrue(takesZaps(FeedProfile(pubkey = "p", lud16 = "band@wavlake.com")))
        assertTrue(takesZaps(FeedProfile(pubkey = "p", lud06 = "lnurl1xyz")))
    }

    /** Both share entry points go through it, and the tray offers Zap (source-level; the sheet needs a device). */
    @Test fun `the tray and the song menu use it`() {
        val base = "src/main/java/com/nostrvault/ui/screens/music/"
        val tray = java.io.File(base + "NowPlayingSheet.kt").readText()
        assertTrue(tray.contains("MusicArtistKey.share(song, actions.onShare)"))
        assertTrue(tray.contains("takesZaps(profiles[it])") && tray.contains("zapModel.zap(hex)"))
        assertFalse(tray.contains("WavlakeLink.shareText("))
        val menu = java.io.File(base + "MusicComponents.kt").readText()
        assertTrue(menu.contains("MusicArtistKey.share(track, actions.onShare)"))
    }
}
