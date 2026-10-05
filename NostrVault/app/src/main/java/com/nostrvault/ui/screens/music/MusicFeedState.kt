package com.nostrvault.ui.screens.music

import com.nostrvault.data.music.WavlakeAlbum
import com.nostrvault.data.music.WavlakeApi
import com.nostrvault.data.music.WavlakeArtist
import com.nostrvault.data.music.WavlakeTrack
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** An artist or album opened inside the Music feed. */
sealed class MusicPage {
    data class Artist(val artist: WavlakeArtist) : MusicPage()
    data class Album(val album: WavlakeAlbum) : MusicPage()

    companion object {
        /** The page for a song's artist, when Wavlake says which. */
        fun artistOf(track: WavlakeTrack): MusicPage? = track.artistId?.let {
            Artist(WavlakeArtist(id = it, name = track.artist, artUrl = track.artistArtUrl, npub = track.artistNpub))
        }

        /** The page for a song's album, when Wavlake says which. */
        fun albumOf(track: WavlakeTrack): MusicPage? = track.albumId?.let {
            Album(
                WavlakeAlbum(
                    id = it, title = track.albumTitle ?: "Album", artUrl = track.albumArtUrl,
                    artist = track.artist, artistId = track.artistId,
                ),
            )
        }
    }
}

/**
 * What the Music feed shows beyond its list: artist and album pages opened
 * over it, and the pages already loaded this launch. One object, so the
 * full player (on any tab) can open a page in the feed. iOS: MusicFeedState.
 */
object MusicFeedState {
    data class ArtistPage(val artist: WavlakeArtist?, val albums: List<WavlakeAlbum>, val tracks: List<WavlakeTrack>)
    data class AlbumPage(val album: WavlakeAlbum?, val tracks: List<WavlakeTrack>)

    /** Pages opened over the feed; the last one is showing. */
    private val _path = MutableStateFlow<List<MusicPage>>(emptyList())
    val path: StateFlow<List<MusicPage>> = _path.asStateFlow()

    /**
     * Set when a page is opened from outside the Music feed (the full
     * player on another tab): the nav graph goes to the Feed tab and the
     * feed switches to Music, which clears it.
     */
    private val _revealRequested = MutableStateFlow(false)
    val revealRequested: StateFlow<Boolean> = _revealRequested.asStateFlow()

    /** Whether the Music feed is on screen; set by [MusicScreen]. */
    var isVisible = false
        internal set

    private val artistPages = mutableMapOf<String, ArtistPage>()
    private val albumPages = mutableMapOf<String, AlbumPage>()

    fun open(page: MusicPage) {
        if (_path.value.lastOrNull() == page) return
        _path.value = _path.value + page
    }

    fun goBack() {
        _path.value = _path.value.dropLast(1)
    }

    fun closePages() {
        _path.value = emptyList()
    }

    /** Opens a page from anywhere: in the feed if it is showing, otherwise the feed is brought up on it. */
    fun reveal(page: MusicPage) {
        if (isVisible) {
            open(page)
        } else {
            _path.value = listOf(page)
            _revealRequested.value = true
        }
    }

    fun consumeReveal() {
        _revealRequested.value = false
    }

    /** The artist page on screen, so a song's "Go to" doesn't offer the page you're on. */
    val showingArtistId: String?
        get() = if (!isVisible) null else (_path.value.lastOrNull() as? MusicPage.Artist)?.artist?.id

    val showingAlbumId: String?
        get() = if (!isVisible) null else (_path.value.lastOrNull() as? MusicPage.Album)?.album?.id

    /**
     * An artist's details, albums (newest first) and the songs on them.
     * Songs come from the newest 25 albums; the albums row lists them all.
     */
    suspend fun artistPage(id: String): ArtistPage? {
        artistPages[id]?.let { return it }
        val (artist, albums) = runCatching { WavlakeApi.artistPage(id) }.getOrNull() ?: return null
        val tracks = WavlakeApi.tracksOnAlbums(albums.take(25))
        val page = ArtistPage(artist, albums, tracks)
        // Every album failing is a bad connection, not an empty artist:
        // show it, but ask again next time.
        if (albums.isNotEmpty() && tracks.isEmpty()) return page
        artistPages[id] = page
        return page
    }

    suspend fun albumPage(id: String): AlbumPage? {
        albumPages[id]?.let { return it }
        val (album, tracks) = runCatching { WavlakeApi.albumPage(id) }.getOrNull() ?: return null
        if (tracks.isEmpty()) return null
        return AlbumPage(album, tracks).also { albumPages[id] = it }
    }
}

/** Counts in page summaries. iOS: MusicCount. */
object MusicCount {
    fun songs(n: Int) = if (n == 1) "1 song" else "$n songs"
    fun albums(n: Int) = if (n == 1) "1 album" else "$n albums"
    fun minutes(seconds: Int): String {
        val minutes = maxOf(1, Math.round(seconds / 60.0).toInt())
        return if (minutes >= 60) "${minutes / 60} hr ${minutes % 60} min" else "$minutes min"
    }
}
