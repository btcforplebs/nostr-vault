package com.nostrvault.ui.screens.music

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.activity.compose.BackHandler
import com.nostrvault.data.music.WavlakeAlbum
import com.nostrvault.data.music.WavlakeArtist
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.music.WavlakeApi
import com.nostrvault.data.music.WavlakeBlockFilter
import com.nostrvault.data.music.WavlakeSearchResult
import com.nostrvault.data.music.WavlakeTrack
import com.nostrvault.service.music.MusicPlayer
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * What a song can lead to outside the music screen: a post sharing it, or
 * the artist's Nostr profile (which carries Follow and Zap).
 */
data class MusicActions(
    val onShare: (String) -> Unit,
    val onOpenProfile: (String) -> Unit,
    val npubToHex: (String) -> String?,
    /** Who you follow, for the toolbar's "Artists you follow". */
    val followedPubkeys: () -> Set<String> = { emptySet() },
    /**
     * Who you block, so their music stays out of the feed. A flow, so
     * blocking an artist clears them as you block.
     */
    val blockedPubkeys: StateFlow<Set<String>> = MutableStateFlow(emptySet()),
)

fun formatTime(sec: Long): String = "%d:%02d".format(sec / 60, sec % 60)

/**
 * The Music feed: Wavlake's trending tracks, and search across songs, albums
 * and artists. Tapping a song plays it and queues the rest of the list after
 * it; the mini player keeps going while you browse. An album or artist opens
 * as a page over the list (Back returns). iOS: MusicBrowserView.
 */
@Composable
fun MusicScreen(actions: MusicActions, contentPadding: PaddingValues) {
    var query by remember { mutableStateOf("") }
    /** The songs for the toolbar's current choice. */
    var trending by remember { mutableStateOf<List<WavlakeTrack>>(emptyList()) }
    /** Following: the artists found, shown above their songs. */
    var followedArtists by remember { mutableStateOf<List<WavlakeArtist>>(emptyList()) }
    val musicScope by MusicFeedState.scope.collectAsState()
    val window by MusicFeedState.trendingWindow.collectAsState()
    val recentArtists by MusicFeedState.recentArtists.collectAsState()
    val picks by MusicFeedState.picks.collectAsState()
    var results by remember { mutableStateOf<List<WavlakeSearchResult>>(emptyList()) }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    // Search keeps its own spinner and message, so clearing a search can't
    // stop the toolbar choice's load, or the other way round.
    var searching by remember { mutableStateOf(false) }
    var searchError by remember { mutableStateOf<String?>(null) }
    val current by MusicPlayer.current.collectAsState()
    val playing by MusicPlayer.isPlaying.collectAsState()
    val path by MusicFeedState.path.collectAsState()
    val blocked by actions.blockedPubkeys.collectAsState()
    // Artist ids known to belong to a blocked key; Wavlake names a key only
    // on an artist's own page, so this is what catches their songs elsewhere.
    val blockedArtists = remember(blocked, recentArtists) {
        WavlakeBlockFilter.blockedArtistIds(MusicFeedState.knownArtists(), blocked, actions.npubToHex)
    }
    // An artist picked in the toolbar shows as a page under the search field.
    val scopeArtist = (musicScope as? MusicScope.Artist)?.artist
    val pageIsScope = path.isEmpty() && scopeArtist != null && query.isBlank()
    val page = path.lastOrNull() ?: if (pageIsScope) MusicPage.Artist(scopeArtist!!) else null
    val listState = rememberLazyListState()

    DisposableEffect(Unit) {
        MusicFeedState.isVisible = true
        onDispose { MusicFeedState.isVisible = false }
    }
    BackHandler(enabled = page != null) {
        if (pageIsScope) MusicFeedState.setScope(MusicScope.Trending) else MusicFeedState.goBack()
    }
    // A toolbar pick replaces whatever search was showing.
    LaunchedEffect(picks) { if (picks > 0) query = "" }
    // Opening or leaving a page starts it at its top.
    LaunchedEffect(page) { listState.scrollToItem(0) }

    var loadAttempt by remember { mutableStateOf(0) }
    // Loads whatever the toolbar picked: trending for the window, or the
    // Wavlake artists you follow. An artist page loads itself.
    LaunchedEffect(musicScope, window, loadAttempt) {
        trending = emptyList(); followedArtists = emptyList()
        loading = true; error = null
        when (musicScope) {
            MusicScope.Trending -> {
                trending = runCatching { WavlakeApi.trending(window.days) }
                    .getOrElse { error = "Couldn't reach Wavlake. Tap to try again."; emptyList() }
                if (trending.isEmpty() && error == null) error = "Nothing trending right now."
            }
            MusicScope.Following -> {
                val follows = actions.followedPubkeys()
                if (follows.isEmpty()) {
                    error = "Follow people on Nostr, and the Wavlake artists among them show up here."
                } else {
                    val (artists, songs) = MusicFeedState.followedArtists(
                        follows, actions.npubToHex, actions.blockedPubkeys.value,
                    )
                    followedArtists = artists; trending = songs
                    if (artists.isEmpty()) {
                        error = "None of the Wavlake artists checked are people you follow. " +
                            "Artists show up here once they link their Nostr key on Wavlake."
                    }
                }
            }
            is MusicScope.Artist -> Unit
        }
        loading = false
    }

    // Search once typing pauses, so each keystroke isn't a request.
    LaunchedEffect(query) {
        val term = query.trim()
        if (term.isEmpty()) { results = emptyList(); searchError = null; searching = false; return@LaunchedEffect }
        delay(400)
        searching = true; searchError = null
        val found = runCatching { WavlakeApi.search(term) }.getOrDefault(emptyList())
        results = found
        searching = false
        if (found.isEmpty()) searchError = "No music found for \"$term\"."
    }

    // The open page's contents, loaded when it opens (cached for Back and forth).
    var artistPage by remember(page) { mutableStateOf<MusicFeedState.ArtistPage?>(null) }
    var albumPage by remember(page) { mutableStateOf<MusicFeedState.AlbumPage?>(null) }
    var pageLoading by remember(page) { mutableStateOf(page != null) }
    var pageAttempt by remember(page) { mutableStateOf(0) }
    LaunchedEffect(page, pageAttempt) {
        when (page) {
            is MusicPage.Artist -> { pageLoading = true; artistPage = MusicFeedState.artistPage(page.artist.id); pageLoading = false }
            is MusicPage.Album -> { pageLoading = true; albumPage = MusicFeedState.albumPage(page.album.id); pageLoading = false }
            null -> Unit
        }
    }

    // Nothing by a blocked artist shows: not their songs, their albums, their
    // artist tiles, nor their search rows. Wavlake keeps it all, so an unblock
    // shows them again.
    val shownResults = remember(results, blocked, blockedArtists) {
        WavlakeBlockFilter.results(results, blocked, blockedArtists, actions.npubToHex)
    }
    val shownTrending = remember(trending, blocked, blockedArtists) {
        WavlakeBlockFilter.tracks(trending, blocked, blockedArtists, actions.npubToHex)
    }
    val shownRecents = remember(recentArtists, blocked, blockedArtists) {
        WavlakeBlockFilter.artists(recentArtists, blocked, blockedArtists, actions.npubToHex)
    }
    val shownFollowed = remember(followedArtists, blocked, blockedArtists) {
        WavlakeBlockFilter.artists(followedArtists, blocked, blockedArtists, actions.npubToHex)
    }
    val tracksOf: List<WavlakeTrack> = when {
        query.isNotBlank() -> shownResults.filterIsInstance<WavlakeSearchResult.Track>().map { it.track }
        else -> shownTrending
    }
    val collections = if (query.isNotBlank()) shownResults.filter { it !is WavlakeSearchResult.Track } else emptyList()
    val accent = LocalNostrVaultColors.current.primary

    LazyColumn(
        state = listState,
        contentPadding = PaddingValues(
            start = 16.dp, end = 16.dp,
            top = contentPadding.calculateTopPadding() + 8.dp,
            bottom = contentPadding.calculateBottomPadding() + 140.dp,
        ),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        when (page) {
            is MusicPage.Artist -> {
                val shown = artistPage?.artist?.let { found ->
                    found.copy(artUrl = found.artUrl ?: page.artist.artUrl, npub = found.npub ?: page.artist.npub)
                } ?: page.artist
                val songs = artistPage?.tracks.orEmpty()
                val albums = artistPage?.albums.orEmpty()
                if (pageIsScope) item(key = "search") { MusicSearchField(query) { query = it } }
                item(key = "page-head") {
                    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
                        MusicBackButton(onBack = if (pageIsScope) ({ MusicFeedState.setScope(MusicScope.Trending) }) else MusicFeedState::goBack)
                        Artwork(shown.artUrl, 148.dp, CircleShape, shadow = 12.dp)
                        Spacer(Modifier.height(8.dp))
                        Text(shown.name, color = PrimaryText, fontSize = 26.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
                        if (albums.isNotEmpty()) {
                            val summary = listOfNotNull(MusicCount.albums(albums.size), songs.takeIf { it.isNotEmpty() }?.let { MusicCount.songs(it.size) })
                            Text(summary.joinToString(" · "), color = SecondaryText, fontSize = 13.sp)
                        }
                        Spacer(Modifier.height(8.dp))
                        MusicPlayButtons(songs) {
                            shown.npub?.let(actions.npubToHex)?.let { hex ->
                                MusicPillButton("On Nostr", Icons.Filled.Person, filled = false) { actions.onOpenProfile(hex) }
                            }
                        }
                    }
                }
                when {
                    pageLoading -> item(key = "page-loading") { MusicSpinner() }
                    artistPage == null || (songs.isEmpty() && albums.isEmpty()) -> item(key = "page-retry") {
                        MusicRetryMessage("Couldn't load ${shown.name}. Tap to try again.") { pageAttempt++ }
                    }
                    else -> {
                        if (albums.isNotEmpty()) item(key = "page-albums") {
                            Column {
                                MusicSectionTitle(if (albums.size == 1) "Album" else "Albums")
                                LazyRow(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                                    items(albums, key = { it.id }) { album ->
                                        CollectionTile(album.title, album.year?.toString() ?: "Album", album.artUrl, RoundedCornerShape(10.dp), 140.dp) {
                                            MusicFeedState.open(MusicPage.Album(album))
                                        }
                                    }
                                }
                            }
                        }
                        if (songs.isNotEmpty()) {
                            item(key = "page-songs") { MusicSectionTitle("Songs") }
                            itemsIndexed(songs, key = { _, t -> "s-${t.id}" }) { index, track ->
                                MusicTrackRow(
                                    track = track, isCurrent = current?.id == track.id, isPlaying = playing, actions = actions,
                                    onTap = { if (current?.id == track.id) MusicPlayer.togglePlayPause() else MusicPlayer.play(songs, index) },
                                )
                            }
                        }
                    }
                }
            }
            is MusicPage.Album -> {
                val tracks = albumPage?.tracks.orEmpty()
                val found = albumPage?.album
                val shown = (found ?: page.album).copy(
                    artUrl = found?.artUrl ?: page.album.artUrl,
                    artist = found?.artist ?: page.album.artist ?: tracks.firstOrNull()?.artist,
                    artistId = found?.artistId ?: page.album.artistId ?: tracks.firstOrNull()?.artistId,
                )
                item(key = "page-head") {
                    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
                        MusicBackButton()
                        Artwork(shown.artUrl, 220.dp, RoundedCornerShape(14.dp), shadow = 14.dp)
                        Spacer(Modifier.height(12.dp))
                        Text(shown.title, color = PrimaryText, fontSize = 22.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
                        shown.artist?.let { name ->
                            val artistId = shown.artistId
                            if (artistId != null) {
                                Text(
                                    name, color = accent, fontSize = 16.sp, fontWeight = FontWeight.SemiBold,
                                    modifier = Modifier.clickable(onClickLabel = "Open the artist") {
                                        openAlbumArtist(artistId, name, tracks)
                                    }.padding(4.dp),
                                )
                            } else {
                                Text(name, color = SecondaryText, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                            }
                        }
                        val seconds = tracks.sumOf { it.duration ?: 0 }
                        val summary = if (albumPage == null) listOfNotNull(shown.year?.toString())
                        else listOfNotNull(shown.year?.toString(), MusicCount.songs(tracks.size), seconds.takeIf { it > 0 }?.let(MusicCount::minutes))
                        if (summary.isNotEmpty()) Text(summary.joinToString(" · "), color = SecondaryText, fontSize = 13.sp)
                        Spacer(Modifier.height(8.dp))
                        MusicPlayButtons(tracks) {}
                    }
                }
                when {
                    pageLoading -> item(key = "page-loading") { MusicSpinner() }
                    albumPage == null -> item(key = "page-retry") {
                        MusicRetryMessage("Couldn't load ${page.album.title}. Tap to try again.") { pageAttempt++ }
                    }
                    else -> itemsIndexed(tracks, key = { _, t -> "a-${t.id}" }) { index, track ->
                        MusicTrackRow(
                            track = track, isCurrent = current?.id == track.id, isPlaying = playing, actions = actions,
                            number = index + 1,
                            onTap = { if (current?.id == track.id) MusicPlayer.togglePlayPause() else MusicPlayer.play(tracks, index) },
                        )
                    }
                }
            }
            null -> {
                item(key = "search") { MusicSearchField(query) { query = it } }
                if (query.isBlank()) {
                    val windowWord = window.title.lowercase()
                    if (musicScope == MusicScope.Trending) {
                        if (shownRecents.isNotEmpty()) item(key = "your-artists") {
                            ArtistRow("Your artists", shownRecents)
                        }
                        val topArtists = MusicTrendingRows.artists(shownTrending)
                        if (topArtists.isNotEmpty()) item(key = "top-artists") {
                            ArtistRow("Top artists $windowWord", topArtists)
                        }
                        val topAlbums = MusicTrendingRows.albums(shownTrending)
                        if (topAlbums.isNotEmpty()) item(key = "top-albums") {
                            Column {
                                MusicSectionTitle("Top albums $windowWord")
                                LazyRow(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                    items(topAlbums, key = { it.id }) { album ->
                                        CollectionTile(album.title, album.artist ?: "Album", album.artUrl, RoundedCornerShape(10.dp), 130.dp) {
                                            MusicFeedState.open(MusicPage.Album(album))
                                        }
                                    }
                                }
                            }
                        }
                        item(key = "header") { MusicSectionTitle("Trending songs $windowWord") }
                    } else {
                        if (shownFollowed.isNotEmpty()) item(key = "followed-artists") {
                            ArtistRow("Artists you follow", shownFollowed)
                        }
                        if (shownTrending.isNotEmpty()) item(key = "header") { MusicSectionTitle("Their songs") }
                    }
                }
                // Search: albums and artists first, then songs; a header only over results.
                if (collections.isNotEmpty()) {
                    item(key = "collections") {
                        Column {
                            MusicSectionTitle("Albums and artists")
                            LazyRow(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                items(collections, key = { it.key }) { result ->
                                    when (result) {
                                        is WavlakeSearchResult.Album -> CollectionTile(result.title, "Album", result.artUrl, RoundedCornerShape(10.dp)) {
                                            MusicFeedState.open(MusicPage.Album(WavlakeAlbum(id = result.id, title = result.title, artUrl = result.artUrl)))
                                        }
                                        is WavlakeSearchResult.Artist -> CollectionTile(result.name, "Artist", result.artUrl, CircleShape) {
                                            MusicFeedState.open(MusicPage.Artist(WavlakeArtist(id = result.id, name = result.name, artUrl = result.artUrl)))
                                        }
                                        is WavlakeSearchResult.Track -> Unit
                                    }
                                }
                            }
                            Spacer(Modifier.height(8.dp))
                        }
                    }
                }
                if (query.isNotBlank() && tracksOf.isNotEmpty()) item(key = "header") { MusicSectionTitle("Songs") }
                itemsIndexed(tracksOf, key = { _, t -> t.id }) { index, track ->
                    MusicTrackRow(
                        track = track,
                        isCurrent = current?.id == track.id,
                        isPlaying = playing,
                        actions = actions,
                        onTap = {
                            if (current?.id == track.id) MusicPlayer.togglePlayPause() else MusicPlayer.play(tracksOf, index)
                        },
                    )
                }
                item(key = "status") {
                    // The toolbar choice's status, or the search's.
                    when (val status = MusicStatus.of(query, loading, error, searching, searchError)) {
                        MusicStatus.Loading -> MusicSpinner()
                        is MusicStatus.Message -> Text(
                            text = status.text, color = SecondaryText, fontSize = 14.sp, textAlign = TextAlign.Center,
                            modifier = Modifier.fillMaxWidth()
                                .clickable(enabled = status.retries) { loadAttempt++ }
                                .padding(vertical = 30.dp),
                        )
                        null -> Unit
                    }
                }
            }
        }
        item(key = "credit") {
            val ctx = LocalContext.current
            Text(
                text = "Music from Wavlake",
                color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth().padding(16.dp)
                    .clickable { runCatching { ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://wavlake.com"))) } },
            )
        }
    }
}

/**
 * The album's artist: opened from that artist's page (or the artist the
 * toolbar picked), Back is the way there; otherwise the artist opens on top.
 */
private fun openAlbumArtist(id: String, name: String, tracks: List<WavlakeTrack>) {
    if (MusicFeedState.albumArtistIsBack(MusicFeedState.path.value, MusicFeedState.currentArtist?.id, id)) {
        MusicFeedState.goBack()
    } else {
        val art = tracks.firstOrNull { it.artistId == id }?.artistArtUrl
        MusicFeedState.open(MusicPage.Artist(WavlakeArtist(id = id, name = name, artUrl = art)))
    }
}

@Composable
private fun MusicSearchField(query: String, onChange: (String) -> Unit) {
    // A filled grey rounded field, as iOS: the secondary colour at 12%.
    val fill = MaterialTheme.colorScheme.onSurfaceVariant.let { it.copy(alpha = it.alpha * 0.12f) }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(fill)
            .padding(start = 12.dp, end = 4.dp).heightIn(min = 44.dp),
    ) {
        Icon(Icons.Filled.Search, contentDescription = null, tint = SecondaryText, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(8.dp))
        Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
            if (query.isEmpty()) Text("Search songs, albums, artists", color = SecondaryText, fontSize = 16.sp)
            BasicTextField(
                value = query,
                onValueChange = onChange,
                singleLine = true,
                textStyle = TextStyle(color = PrimaryText, fontSize = 16.sp),
                cursorBrush = SolidColor(LocalNostrVaultColors.current.primary),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search, autoCorrectEnabled = false),
                modifier = Modifier.fillMaxWidth().semantics { contentDescription = "Search songs, albums, artists" },
            )
        }
        if (query.isNotEmpty()) IconButton(onClick = { onChange("") }, modifier = Modifier.size(40.dp)) {
            Icon(Icons.Filled.Cancel, contentDescription = "Clear search", tint = SecondaryText, modifier = Modifier.size(18.dp))
        }
        if (query.isEmpty()) Spacer(Modifier.width(8.dp))
    }
}

/** Round artist pictures in a sideways row; tap one for their page. */
@Composable
private fun ArtistRow(title: String, artists: List<WavlakeArtist>) {
    Column {
        MusicSectionTitle(title)
        LazyRow(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            items(artists, key = { it.id }) { artist ->
                CollectionTile(artist.name, "Artist", artist.artUrl, CircleShape, 96.dp) {
                    MusicFeedState.open(MusicPage.Artist(artist))
                }
            }
        }
    }
}
