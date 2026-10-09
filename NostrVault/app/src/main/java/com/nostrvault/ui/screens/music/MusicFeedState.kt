package com.nostrvault.ui.screens.music

import com.nostrvault.data.music.WavlakeAlbum
import com.nostrvault.data.music.WavlakeApi
import com.nostrvault.data.music.WavlakeArtist
import com.nostrvault.data.music.WavlakeTrack
import android.content.Context
import android.content.SharedPreferences
import com.nostrvault.service.music.MusicPlayer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.mapNotNull
import kotlinx.coroutines.flow.onEach
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

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

/** What the Music toolbar picked to show. */
sealed class MusicScope {
    data object Trending : MusicScope()
    data class Artist(val artist: WavlakeArtist) : MusicScope()
    data object Following : MusicScope()
}

/** The rankings windows offered as words. Wavlake answers 1 to 90 days. */
enum class TrendingWindow(val days: Int, val title: String) {
    WEEK(7, "This week"),
    MONTH(30, "This month"),
}

/**
 * What the Music feed shows beyond its list: artist and album pages opened
 * over it, and the pages already loaded this launch. One object, so the
 * full player (on any tab) can open a page in the feed. iOS: MusicFeedState.
 */
object MusicFeedState {
    data class ArtistPage(val artist: WavlakeArtist?, val albums: List<WavlakeAlbum>, val tracks: List<WavlakeTrack>)
    data class AlbumPage(val album: WavlakeAlbum?, val tracks: List<WavlakeTrack>)

    private const val PREFS = "music_feed"
    private const val RECENT_KEY = "recentArtists"
    private const val MAX_RECENT = 20
    private val json = Json { ignoreUnknownKeys = true }
    private var prefs: SharedPreferences? = null

    /** Any toolbar pick, even the one already showing, closes open pages and the search. */
    private val _scope = MutableStateFlow<MusicScope>(MusicScope.Trending)
    val scope: StateFlow<MusicScope> = _scope.asStateFlow()
    /** Counts toolbar picks, so the feed can clear its search on a pick that doesn't change what loads. */
    private val _picks = MutableStateFlow(0)
    val picks: StateFlow<Int> = _picks.asStateFlow()
    private val _trendingWindow = MutableStateFlow(TrendingWindow.WEEK)
    val trendingWindow: StateFlow<TrendingWindow> = _trendingWindow.asStateFlow()
    /** Artists you've played or opened, newest first. Kept across launches. */
    private val _recentArtists = MutableStateFlow<List<WavlakeArtist>>(emptyList())
    val recentArtists: StateFlow<List<WavlakeArtist>> = _recentArtists.asStateFlow()
    /** Artist pages fetched this launch, for their Nostr keys. */
    private val artistCache = mutableMapOf<String, WavlakeArtist>()

    /** Loads the saved artists, and adds the artist of every song that starts, from the feed or a post. */
    @OptIn(FlowPreview::class)
    fun init(context: Context) {
        if (prefs != null) return
        val p = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs = p
        _recentArtists.value = p.getString(RECENT_KEY, null)
            ?.let { runCatching { json.decodeFromString(ListSerializer(WavlakeArtist.serializer()), it) }.getOrNull() }
            .orEmpty()
        MusicPlayer.current
            .debounce(300)
            .mapNotNull { it?.wavlake }
            .distinctUntilChanged { a, b -> a.artistId == b.artistId }
            .onEach(::remember)
            .launchIn(CoroutineScope(SupervisorJob() + Dispatchers.Main))
    }

    fun setScope(scope: MusicScope) {
        _scope.value = scope
        _path.value = emptyList()
        _picks.value++
    }

    fun showTrending(window: TrendingWindow) {
        _trendingWindow.value = window
        setScope(MusicScope.Trending)
    }

    fun show(artist: WavlakeArtist) {
        remember(artist)
        setScope(MusicScope.Artist(artist))
    }

    val currentArtist: WavlakeArtist? get() = (_scope.value as? MusicScope.Artist)?.artist

    fun remember(track: WavlakeTrack) {
        val id = track.artistId ?: return
        remember(WavlakeArtist(id = id, name = track.artist, artUrl = track.artistArtUrl, npub = track.artistNpub))
    }

    fun remember(artist: WavlakeArtist) {
        _recentArtists.value = MusicRecentArtists.add(_recentArtists.value, artist, MAX_RECENT)
        saveRecent()
    }

    fun clearRecentArtists() {
        _recentArtists.value = emptyList()
        saveRecent()
    }

    private fun saveRecent() {
        prefs?.edit()?.putString(RECENT_KEY, json.encodeToString(ListSerializer(WavlakeArtist.serializer()), _recentArtists.value))?.apply()
    }

    /**
     * Wavlake artists whose linked Nostr key you follow, and their ranked
     * songs. Wavlake can't be asked which artists a key follows, and only an
     * artist's own page carries their key, so this checks the artists of the
     * last 90 days' rankings plus your recent artists.
     */
    suspend fun followedArtists(
        follows: Set<String>,
        npubToHex: (String) -> String?,
    ): Pair<List<WavlakeArtist>, List<WavlakeTrack>> {
        val ranked = runCatching { WavlakeApi.trending(days = 90) }.getOrDefault(emptyList())
        val ids = (_recentArtists.value.map { it.id } + ranked.mapNotNull { it.artistId }).distinct()
        val missing = ids.filter { it !in artistCache }
        coroutineScope {
            missing.map { id -> async { runCatching { WavlakeApi.artist(id) }.getOrNull() } }.awaitAll()
        }.filterNotNull().forEach { artistCache[it.id] = it }
        val artists = ids.mapNotNull { artistCache[it] }.filter { a ->
            a.npub?.let(npubToHex)?.let { it in follows } == true
        }
        val followed = artists.map { it.id }.toSet()
        return artists to ranked.filter { it.artistId in followed }
    }

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
        if (page is MusicPage.Artist) remember(page.artist)
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
            if (page is MusicPage.Artist) remember(page.artist)
            _path.value = listOf(page)
            _revealRequested.value = true
        }
    }

    fun consumeReveal() {
        _revealRequested.value = false
    }

    /** The artist page on screen, so a song's "Go to" doesn't offer the page you're on. */
    val showingArtistId: String?
        get() = if (!isVisible) null else when (val last = _path.value.lastOrNull()) {
            is MusicPage.Artist -> last.artist.id
            is MusicPage.Album -> null
            null -> currentArtist?.id
        }

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

/**
 * Trending is ranked by song, so its artists and albums come out in the
 * order their best song places. A row this long is plenty.
 */
object MusicTrendingRows {
    const val ROW_LIMIT = 15

    fun artists(tracks: List<WavlakeTrack>): List<WavlakeArtist> = tracks
        .mapNotNull { t -> t.artistId?.let { WavlakeArtist(id = it, name = t.artist, artUrl = t.artistArtUrl, npub = t.artistNpub) } }
        .distinctBy { it.id }
        .take(ROW_LIMIT)

    fun albums(tracks: List<WavlakeTrack>): List<WavlakeAlbum> = tracks
        .mapNotNull { t ->
            t.albumId?.let {
                WavlakeAlbum(id = it, title = t.albumTitle ?: "Album", artUrl = t.albumArtUrl, artist = t.artist, artistId = t.artistId)
            }
        }
        .distinctBy { it.id }
        .take(ROW_LIMIT)
}

/** The recent-artists list: newest first, once each, capped. */
object MusicRecentArtists {
    fun add(list: List<WavlakeArtist>, artist: WavlakeArtist, max: Int): List<WavlakeArtist> {
        val known = list.firstOrNull { it.id == artist.id }
        val merged = artist.copy(artUrl = artist.artUrl ?: known?.artUrl, npub = artist.npub ?: known?.npub)
        return (listOf(merged) + list.filter { it.id != artist.id }).take(max)
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
