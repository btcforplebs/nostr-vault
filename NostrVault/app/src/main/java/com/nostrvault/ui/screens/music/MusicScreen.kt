package com.nostrvault.ui.screens.music

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
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
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.activity.compose.BackHandler
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import com.nostrvault.data.music.WavlakeAlbum
import com.nostrvault.data.music.WavlakeArtist
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import com.nostrvault.data.music.WavlakeApi
import com.nostrvault.data.music.WavlakeLink
import com.nostrvault.data.music.WavlakeSearchResult
import com.nostrvault.data.music.WavlakeTrack
import com.nostrvault.service.music.MusicPlayer
import com.nostrvault.service.music.MusicRepeatMode
import com.nostrvault.service.music.PlayerTrack
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * What a song can lead to outside the music screen: a post sharing it, or
 * the artist's Nostr profile (which carries Follow and Zap).
 */
data class MusicActions(
    val onShare: (String) -> Unit,
    val onOpenProfile: (String) -> Unit,
    val npubToHex: (String) -> String?,
)

private fun formatTime(sec: Long): String = "%d:%02d".format(sec / 60, sec % 60)

/**
 * The Music feed: Wavlake's trending tracks, and search across songs, albums
 * and artists. Tapping a song plays it and queues the rest of the list after
 * it; the mini player keeps going while you browse. An album or artist opens
 * as a page over the list (Back returns). iOS: MusicBrowserView.
 */
@Composable
fun MusicScreen(actions: MusicActions, contentPadding: PaddingValues) {
    val scope = rememberCoroutineScope()
    var query by remember { mutableStateOf("") }
    var trending by remember { mutableStateOf<List<WavlakeTrack>>(emptyList()) }
    var results by remember { mutableStateOf<List<WavlakeSearchResult>>(emptyList()) }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val current by MusicPlayer.current.collectAsState()
    val playing by MusicPlayer.isPlaying.collectAsState()
    val path by MusicFeedState.path.collectAsState()
    val page = path.lastOrNull()
    val listState = rememberLazyListState()

    DisposableEffect(Unit) {
        MusicFeedState.isVisible = true
        onDispose { MusicFeedState.isVisible = false }
    }
    BackHandler(enabled = page != null) { MusicFeedState.goBack() }
    // Opening or leaving a page starts it at its top.
    LaunchedEffect(page) { listState.scrollToItem(0) }

    suspend fun loadTrending() {
        loading = true; error = null
        trending = runCatching { WavlakeApi.trending() }.getOrElse { error = "Couldn't reach Wavlake. Tap to try again."; emptyList() }
        if (trending.isEmpty() && error == null) error = "Nothing trending right now."
        loading = false
    }

    LaunchedEffect(Unit) { if (trending.isEmpty()) loadTrending() }

    // Search once typing pauses, so each keystroke isn't a request.
    LaunchedEffect(query) {
        val term = query.trim()
        if (term.isEmpty()) { results = emptyList(); error = null; loading = false; return@LaunchedEffect }
        delay(400)
        loading = true; error = null
        val found = runCatching { WavlakeApi.search(term) }.getOrDefault(emptyList())
        results = found
        loading = false
        if (found.isEmpty()) error = "No music found for \"$term\"."
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

    val tracksOf: List<WavlakeTrack> = when {
        query.isNotBlank() -> results.filterIsInstance<WavlakeSearchResult.Track>().map { it.track }
        else -> trending
    }
    val collections = if (query.isNotBlank()) results.filter { it !is WavlakeSearchResult.Track } else emptyList()
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
                item(key = "page-head") {
                    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
                        MusicBackButton()
                        Artwork(shown.artUrl, 148.dp, CircleShape)
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
                        Artwork(shown.artUrl, 220.dp, RoundedCornerShape(14.dp))
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
                item(key = "search") {
                    OutlinedTextField(
                        value = query,
                        onValueChange = { query = it },
                        placeholder = { Text("Search songs, albums, artists") },
                        leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                        trailingIcon = {
                            if (query.isNotEmpty()) IconButton(onClick = { query = "" }) {
                                Icon(Icons.Filled.Close, contentDescription = "Clear search")
                            }
                        },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                item(key = "header") {
                    Text(
                        text = if (query.isNotBlank()) "Songs" else "Trending on Wavlake",
                        color = PrimaryText, fontSize = 18.sp, fontWeight = FontWeight.Bold,
                        modifier = Modifier.padding(top = 8.dp),
                    )
                }
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
                    when {
                        loading -> MusicSpinner()
                        error != null -> Text(
                            text = error!!, color = SecondaryText, fontSize = 14.sp,
                            modifier = Modifier.fillMaxWidth().padding(24.dp)
                                .clickable(enabled = query.isBlank()) { scope.launch { loadTrending() } },
                        )
                    }
                }
            }
        }
        item(key = "credit") {
            val ctx = LocalContext.current
            Text(
                text = "Music from Wavlake",
                color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.fillMaxWidth().padding(16.dp)
                    .clickable { ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://wavlake.com"))) },
            )
        }
    }
}

/**
 * The album's artist: opened from that artist's page, Back is the way
 * there; otherwise the artist opens on top.
 */
private fun openAlbumArtist(id: String, name: String, tracks: List<WavlakeTrack>) {
    val path = MusicFeedState.path.value
    val previous = path.getOrNull(path.size - 2) as? MusicPage.Artist
    if (previous?.artist?.id == id) {
        MusicFeedState.goBack()
    } else {
        val art = tracks.firstOrNull { it.artistId == id }?.artistArtUrl
        MusicFeedState.open(MusicPage.Artist(WavlakeArtist(id = id, name = name, artUrl = art)))
    }
}

@Composable
private fun MusicSpinner() {
    Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(color = LocalNostrVaultColors.current.primary)
    }
}

@Composable
private fun MusicBackButton() {
    Box(Modifier.fillMaxWidth()) {
        TextButton(onClick = MusicFeedState::goBack) {
            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(4.dp))
            Text("Back")
        }
    }
}

@Composable
private fun MusicSectionTitle(title: String) {
    Text(
        title, color = PrimaryText, fontSize = 18.sp, fontWeight = FontWeight.Bold,
        modifier = Modifier.padding(top = 8.dp, bottom = 8.dp).semantics { heading() },
    )
}

@Composable
private fun MusicRetryMessage(text: String, retry: () -> Unit) {
    Text(
        text, color = SecondaryText, fontSize = 14.sp, textAlign = TextAlign.Center,
        modifier = Modifier.fillMaxWidth().clickable(onClick = retry).padding(vertical = 30.dp),
    )
}

/** Play from the top and Shuffle, plus any extra pill. Disabled until there are songs. iOS: MusicPlayButtons. */
@Composable
private fun MusicPlayButtons(tracks: List<WavlakeTrack>, extra: @Composable () -> Unit) {
    val enabled = tracks.isNotEmpty()
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.alpha(if (enabled) 1f else 0.5f)) {
        MusicPillButton("Play", Icons.Filled.PlayArrow, filled = true, enabled = enabled) { MusicPlayer.play(tracks) }
        MusicPillButton("Shuffle", Icons.Filled.Shuffle, filled = false, enabled = enabled) { MusicPlayer.playShuffled(tracks) }
        extra()
    }
}

@Composable
private fun MusicPillButton(
    title: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    filled: Boolean,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    val accent = LocalNostrVaultColors.current.primary
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .heightIn(min = 36.dp)
            .clip(CircleShape)
            .background(if (filled) accent else accent.copy(alpha = 0.14f))
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = 16.dp),
    ) {
        Icon(icon, contentDescription = null, tint = if (filled) Color.White else accent, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(6.dp))
        Text(title, color = if (filled) Color.White else accent, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun CollectionTile(
    title: String,
    subtitle: String,
    art: String?,
    shape: Shape,
    size: androidx.compose.ui.unit.Dp = 110.dp,
    onClick: () -> Unit,
) {
    Column(Modifier.width(size).clickable(onClick = onClick)) {
        Artwork(art, size, shape)
        Text(title, color = PrimaryText, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
        Text(subtitle, color = SecondaryText, fontSize = 11.sp)
    }
}

@Composable
fun Artwork(url: String?, size: androidx.compose.ui.unit.Dp, shape: Shape = RoundedCornerShape(8.dp)) {
    Box(Modifier.size(size).clip(shape).background(Color.White.copy(alpha = 0.08f)), contentAlignment = Alignment.Center) {
        Icon(Icons.Filled.MusicNote, contentDescription = null, tint = SecondaryText)
        if (url != null) AsyncImage(model = url, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.matchParentSize())
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun MusicTrackRow(
    track: WavlakeTrack,
    isCurrent: Boolean,
    isPlaying: Boolean,
    actions: MusicActions,
    /** Album order: the track number shows instead of the cover. */
    number: Int? = null,
    onTap: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    val ctx = LocalContext.current
    Box {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .combinedClickable(role = Role.Button, onClick = onTap, onLongClick = { menu = true })
                .padding(vertical = 6.dp)
                .semantics { contentDescription = "${track.title}, ${track.artist}" },
        ) {
            if (number != null) Box(Modifier.size(width = 28.dp, height = 40.dp), contentAlignment = Alignment.Center) {
                if (isCurrent) {
                    Icon(
                        if (isPlaying) Icons.Filled.GraphicEq else Icons.Filled.PlayArrow,
                        contentDescription = null, tint = LocalNostrVaultColors.current.primary, modifier = Modifier.size(18.dp),
                    )
                } else {
                    Text("$number", color = SecondaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                }
            } else Box(contentAlignment = Alignment.Center) {
                Artwork(track.albumArtUrl, 48.dp)
                if (isCurrent) {
                    Box(Modifier.size(48.dp).clip(RoundedCornerShape(8.dp)).background(Color.Black.copy(alpha = 0.45f)))
                    Icon(
                        if (isPlaying) Icons.Filled.GraphicEq else Icons.Filled.PlayArrow,
                        contentDescription = null, tint = Color.White,
                    )
                }
            }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    track.title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    color = if (isCurrent) LocalNostrVaultColors.current.primary else PrimaryText,
                )
                Text(track.artist, color = SecondaryText, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            track.sats?.takeIf { it > 0 }?.let { sats ->
                Text("⚡ %,d".format(sats), color = Color(0xFFF7931A), fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.width(8.dp))
            }
            track.duration?.takeIf { it > 0 }?.let { Text(formatTime(it.toLong()), color = SecondaryText, fontSize = 12.sp) }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            MusicPage.artistOf(track)?.takeIf { MusicFeedState.showingArtistId != track.artistId }?.let { page ->
                DropdownMenuItem(text = { Text("Go to ${track.artist}") }, onClick = { menu = false; MusicFeedState.reveal(page) })
            }
            MusicPage.albumOf(track)?.takeIf { MusicFeedState.showingAlbumId != track.albumId }?.let { page ->
                DropdownMenuItem(
                    text = { Text(track.albumTitle?.let { "Go to $it" } ?: "Go to album") },
                    onClick = { menu = false; MusicFeedState.reveal(page) },
                )
            }
            DropdownMenuItem(text = { Text("Share to Nostr") }, onClick = { menu = false; actions.onShare(WavlakeLink.shareText(track)) })
            track.artistNpub?.let(actions.npubToHex)?.let { hex ->
                DropdownMenuItem(text = { Text("${track.artist} on Nostr") }, onClick = { menu = false; actions.onOpenProfile(hex) })
            }
            DropdownMenuItem(text = { Text("Open on Wavlake") }, onClick = {
                menu = false; ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(track.pageUrl)))
            })
        }
    }
}

// ── Mini player ─────────────────────────────────────────────────

/**
 * Sits above the bottom bar on every tab while a song or live stream is
 * loaded: artwork, title, play/pause, next and ✕, with a thin progress line.
 * Tap it for the full player. iOS: MiniPlayerBar.
 */
@Composable
fun MiniPlayerBar(actions: MusicActions, modifier: Modifier = Modifier) {
    val track by MusicPlayer.current.collectAsState()
    val playing by MusicPlayer.isPlaying.collectAsState()
    val buffering by MusicPlayer.isBuffering.collectAsState()
    val hasNext by MusicPlayer.hasNext.collectAsState()
    val position by MusicPlayer.positionMs.collectAsState()
    val duration by MusicPlayer.durationMs.collectAsState()
    var showFull by remember { mutableStateOf(false) }
    val t = track ?: return

    Box(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp)
            .height(52.dp)
            .clip(RoundedCornerShape(26.dp))
            .background(Color(0xFF1E1E22).copy(alpha = 0.96f))
            .border(1.dp, Color.White.copy(alpha = 0.12f), RoundedCornerShape(26.dp))
            .clickable(onClickLabel = "Open the player") { showFull = true },
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxSize().padding(start = 6.dp)) {
            Artwork(t.artworkUrl, 40.dp, CircleShape)
            Spacer(Modifier.width(8.dp))
            Column(Modifier.weight(1f)) {
                Text(t.title, color = PrimaryText, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (t.isLive) { LiveBadge(); Spacer(Modifier.width(5.dp)) }
                    Text(t.artist, color = SecondaryText, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            if (buffering && playing) {
                Box(Modifier.size(44.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp) }
            } else {
                IconButton(onClick = MusicPlayer::togglePlayPause, modifier = Modifier.size(44.dp)) {
                    Icon(if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow, contentDescription = if (playing) "Pause" else "Play", tint = PrimaryText)
                }
            }
            if (!t.isLive) {
                IconButton(onClick = MusicPlayer::next, enabled = hasNext, modifier = Modifier.size(44.dp)) {
                    Icon(Icons.Filled.SkipNext, contentDescription = "Next song", tint = if (hasNext) PrimaryText else SecondaryText.copy(alpha = 0.35f))
                }
            }
            IconButton(onClick = MusicPlayer::stop, modifier = Modifier.size(44.dp)) {
                Icon(Icons.Filled.Close, contentDescription = "Stop music", tint = SecondaryText)
            }
        }
        if (!t.isLive && duration > 0) {
            Box(
                Modifier.align(Alignment.BottomStart).padding(horizontal = 18.dp, vertical = 3.dp)
                    .fillMaxWidth((position.toFloat() / duration).coerceIn(0f, 1f))
                    .height(2.dp).clip(RoundedCornerShape(1.dp))
                    .background(LocalNostrVaultColors.current.primary),
            )
        }
    }
    if (showFull) NowPlayingSheet(actions = actions, onDismiss = { showFull = false })
}

@Composable
fun LiveBadge() {
    Text(
        "LIVE", color = Color.White, fontSize = 10.sp, fontWeight = FontWeight.Black,
        modifier = Modifier.clip(RoundedCornerShape(50)).background(Color.Red).padding(horizontal = 5.dp, vertical = 1.dp),
    )
}

/** Full player: big artwork, scrubber, shuffle / previous / play / next / repeat, the song's pages, Share and Up Next. */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun NowPlayingSheet(actions: MusicActions, onDismiss: () -> Unit) {
    val track by MusicPlayer.current.collectAsState()
    val playing by MusicPlayer.isPlaying.collectAsState()
    val hasNext by MusicPlayer.hasNext.collectAsState()
    val position by MusicPlayer.positionMs.collectAsState()
    val duration by MusicPlayer.durationMs.collectAsState()
    val shuffled by MusicPlayer.isShuffled.collectAsState()
    val repeat by MusicPlayer.repeatMode.collectAsState()
    var scrub by remember { mutableStateOf<Float?>(null) }
    var showingQueue by remember { mutableStateOf(false) }
    val ctx = LocalContext.current
    val t = track
    LaunchedEffect(t) { if (t == null) onDismiss() }
    if (t == null) return
    // Closes the player and opens the page in the Music feed.
    val go: (MusicPage) -> Unit = { page -> onDismiss(); MusicFeedState.reveal(page) }

    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = Color(0xFF151518)) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 32.dp),
        ) {
            // Up Next takes the artwork's place, so the controls stay put.
            Box(Modifier.height(280.dp).fillMaxWidth(), contentAlignment = Alignment.Center) {
                if (showingQueue && !t.isLive) UpNextList(shuffled = shuffled, repeat = repeat)
                else Artwork(t.artworkUrl, 280.dp, RoundedCornerShape(18.dp))
            }
            Spacer(Modifier.height(20.dp))
            if (t.isLive) LiveBadge()
            Text(t.title, color = PrimaryText, fontSize = 22.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center, maxLines = 2)
            // The artist and album open their pages.
            val artistPage = t.wavlake?.let(MusicPage::artistOf)
            val albumPage = t.wavlake?.let(MusicPage::albumOf)
            if (artistPage != null) {
                PageLinkText(t.artist, 16.sp, FontWeight.SemiBold, "Open the artist") { go(artistPage) }
            } else {
                Text(t.artist, color = SecondaryText, fontSize = 16.sp)
            }
            val albumTitle = t.wavlake?.albumTitle
            if (albumPage != null && albumTitle != null && albumTitle != t.title) {
                PageLinkText(albumTitle, 13.sp, FontWeight.Normal, "Open the album") { go(albumPage) }
            }
            Spacer(Modifier.height(16.dp))
            if (!t.isLive) {
                val dur = duration.coerceAtLeast(1)
                Slider(
                    value = scrub ?: (position.toFloat() / dur).coerceIn(0f, 1f),
                    onValueChange = { scrub = it },
                    onValueChangeFinished = { scrub?.let { MusicPlayer.seekTo((it * dur).toLong()) }; scrub = null },
                )
                Row(Modifier.fillMaxWidth()) {
                    Text(formatTime(((scrub?.times(dur))?.toLong() ?: position) / 1000), color = SecondaryText, fontSize = 12.sp)
                    Spacer(Modifier.weight(1f))
                    Text(formatTime(duration / 1000), color = SecondaryText, fontSize = 12.sp)
                }
            }
            // Shuffle and repeat flank the usual three; live has only play/pause.
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = if (t.isLive) Arrangement.Center else Arrangement.SpaceBetween,
                modifier = Modifier.fillMaxWidth(),
            ) {
                if (!t.isLive) MusicModeButton(
                    icon = Icons.Filled.Shuffle, isOn = shuffled, label = "Shuffle",
                    value = if (shuffled) "On" else "Off", onClick = MusicPlayer::toggleShuffle,
                )
                if (!t.isLive) IconButton(onClick = MusicPlayer::previous, modifier = Modifier.size(56.dp)) {
                    Icon(Icons.Filled.SkipPrevious, contentDescription = "Previous", tint = PrimaryText, modifier = Modifier.size(34.dp))
                }
                IconButton(onClick = MusicPlayer::togglePlayPause, modifier = Modifier.size(72.dp)) {
                    Icon(
                        if (playing) Icons.Filled.PauseCircle else Icons.Filled.PlayCircle,
                        contentDescription = if (playing) "Pause" else "Play",
                        tint = LocalNostrVaultColors.current.primary, modifier = Modifier.size(68.dp),
                    )
                }
                if (!t.isLive) IconButton(onClick = MusicPlayer::next, enabled = hasNext, modifier = Modifier.size(56.dp)) {
                    Icon(Icons.Filled.SkipNext, contentDescription = "Next", tint = if (hasNext) PrimaryText else SecondaryText, modifier = Modifier.size(34.dp))
                }
                if (!t.isLive) MusicModeButton(
                    icon = if (repeat == MusicRepeatMode.ONE) Icons.Filled.RepeatOne else Icons.Filled.Repeat,
                    isOn = repeat != MusicRepeatMode.OFF, label = "Repeat",
                    value = when (repeat) {
                        MusicRepeatMode.OFF -> "Off"
                        MusicRepeatMode.ALL -> "All"
                        MusicRepeatMode.ONE -> "This song"
                    },
                    onClick = MusicPlayer::cycleRepeat,
                )
            }
            Spacer(Modifier.height(16.dp))
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.CenterHorizontally),
                verticalArrangement = Arrangement.Center,
            ) {
                t.wavlake?.let { song ->
                    MusicPage.artistOf(song)?.let { page ->
                        AssistChip(onClick = { go(page) }, label = { Text("Artist") },
                            leadingIcon = { Icon(Icons.Filled.Mic, null) })
                    }
                    MusicPage.albumOf(song)?.let { page ->
                        AssistChip(onClick = { go(page) }, label = { Text("Album") },
                            leadingIcon = { Icon(Icons.Filled.Album, null) })
                    }
                    AssistChip(onClick = { onDismiss(); actions.onShare(WavlakeLink.shareText(song)) }, label = { Text("Share") },
                        leadingIcon = { Icon(Icons.Filled.Share, null) })
                    song.artistNpub?.let(actions.npubToHex)?.let { hex ->
                        AssistChip(onClick = { onDismiss(); actions.onOpenProfile(hex) }, label = { Text("On Nostr") },
                            leadingIcon = { Icon(Icons.Filled.Person, null) })
                    }
                }
                t.hostPubkey?.let { host ->
                    AssistChip(onClick = { onDismiss(); actions.onOpenProfile(host) }, label = { Text("Host") },
                        leadingIcon = { Icon(Icons.Filled.Person, null) })
                }
                if (!t.isLive) MusicModeButton(
                    icon = Icons.AutoMirrored.Filled.QueueMusic, isOn = showingQueue, label = "Up Next",
                    value = if (showingQueue) "Showing" else "Hidden", onClick = { showingQueue = !showingQueue },
                )
            }
            t.pageUrl?.let { page ->
                TextButton(onClick = { ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(page))) }) {
                    Text(if (t.isLive) "Open stream" else "Open on Wavlake", color = SecondaryText)
                }
            }
        }
    }
}

/** The songs after this one, in play order; tap one to play it now. iOS: NowPlayingView.upNext. */
@Composable
private fun UpNextList(shuffled: Boolean, repeat: MusicRepeatMode) {
    val queue by MusicPlayer.queueState.collectAsState()
    val index by MusicPlayer.index.collectAsState()
    val upcoming = queue.drop(index + 1)
    val accent = LocalNostrVaultColors.current.primary
    Column(Modifier.fillMaxSize()) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp)) {
            Text("Up Next", color = PrimaryText, fontSize = 17.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
            if (shuffled) {
                Icon(Icons.Filled.Shuffle, contentDescription = null, tint = accent, modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(4.dp))
                Text("Shuffled", color = accent, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
            }
        }
        if (upcoming.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(
                    if (repeat == MusicRepeatMode.ALL) "The queue starts over after this song." else "Nothing after this song.",
                    color = SecondaryText, fontSize = 14.sp,
                )
            }
        } else {
            LazyColumn(Modifier.fillMaxSize()) {
                itemsIndexed(upcoming) { offset, item ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable(onClickLabel = "Play this song now") { MusicPlayer.jump(index + 1 + offset) }
                            .padding(vertical = 4.dp),
                    ) {
                        Artwork(item.artworkUrl, 40.dp, RoundedCornerShape(6.dp))
                        Spacer(Modifier.width(10.dp))
                        Column(Modifier.weight(1f)) {
                            Text(item.title, color = PrimaryText, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(item.artist, color = SecondaryText, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                        item.durationSec?.takeIf { it > 0 }?.let { Text(formatTime(it.toLong()), color = SecondaryText, fontSize = 12.sp) }
                    }
                }
            }
        }
    }
}

@Composable
private fun PageLinkText(
    text: String,
    size: androidx.compose.ui.unit.TextUnit,
    weight: FontWeight,
    hint: String,
    onClick: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.clickable(onClickLabel = hint, onClick = onClick).padding(horizontal = 4.dp, vertical = 2.dp),
    ) {
        Text(text, color = LocalNostrVaultColors.current.primary, fontSize = size, fontWeight = weight, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = LocalNostrVaultColors.current.primary, modifier = Modifier.size(16.dp))
    }
}

/** Shuffle or repeat: accent on a soft accent disc when on. */
@Composable
private fun MusicModeButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    isOn: Boolean,
    label: String,
    value: String,
    onClick: () -> Unit,
) {
    val accent = LocalNostrVaultColors.current.primary
    IconButton(
        onClick = onClick,
        modifier = Modifier
            .size(44.dp)
            .clip(CircleShape)
            .background(accent.copy(alpha = if (isOn) 0.18f else 0f))
            .semantics { stateDescription = value },
    ) {
        Icon(icon, contentDescription = label, tint = if (isOn) accent else SecondaryText, modifier = Modifier.size(22.dp))
    }
}

// ── Songs in posts ──────────────────────────────────────────────

private val trackCache = mutableMapOf<String, WavlakeTrack>()

/**
 * A Wavlake song inside a post: artwork, title, artist and a play button,
 * in place of the generic link preview. Reposts and quotes of the song play
 * the same way. iOS: WavlakeTrackCard.
 */
@Composable
fun WavlakeTrackCard(trackId: String, modifier: Modifier = Modifier) {
    var track by remember(trackId) { mutableStateOf(trackCache[trackId]) }
    var failed by remember(trackId) { mutableStateOf(false) }
    val current by MusicPlayer.current.collectAsState()
    val playing by MusicPlayer.isPlaying.collectAsState()
    LaunchedEffect(trackId) {
        if (track == null) {
            val found = runCatching { WavlakeApi.track(trackId) }.getOrNull()
            if (found != null) { trackCache[trackId] = found; track = found } else failed = true
        }
    }
    val t = track
    if (t == null) {
        if (!failed) Box(modifier.fillMaxWidth().height(68.dp).clip(RoundedCornerShape(12.dp)).background(Color.White.copy(alpha = 0.06f)))
        return
    }
    val isCurrent = current?.id == t.id
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Color.White.copy(alpha = 0.06f)).padding(10.dp),
    ) {
        Artwork(t.albumArtUrl, 52.dp)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(t.title, color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(t.artist, color = SecondaryText, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text("♪ Wavlake", color = SecondaryText, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
        }
        IconButton(onClick = { if (isCurrent) MusicPlayer.togglePlayPause() else MusicPlayer.play(listOf(t)) }, modifier = Modifier.size(48.dp)) {
            Icon(
                if (isCurrent && playing) Icons.Filled.PauseCircle else Icons.Filled.PlayCircle,
                contentDescription = if (isCurrent && playing) "Pause ${t.title}" else "Play ${t.title}",
                tint = LocalNostrVaultColors.current.primary, modifier = Modifier.size(40.dp),
            )
        }
    }
}

/**
 * An audio file shared in a post (an MP3 link): a play button on the
 * app-wide player, so it keeps going in the mini player, the notification
 * and on the lock screen like a Wavlake song. iOS: FeedAudioCard.
 */
@Composable
fun AudioFileCard(url: String, modifier: Modifier = Modifier) {
    val current by MusicPlayer.current.collectAsState()
    val playing by MusicPlayer.isPlaying.collectAsState()
    val uri = remember(url) { android.net.Uri.parse(url) }
    val title = remember(url) {
        val name = uri.lastPathSegment.orEmpty().substringBeforeLast('.')
        // A Blossom hash, or no file name at all, says nothing to a person.
        val isHash = name.length == 64 && name.all { it.isDigit() || it.lowercaseChar() in 'a'..'f' }
        if (name.isBlank() || isHash) "Audio" else name
    }
    val ext = remember(url) { url.substringAfterLast('.').substringBefore('?').substringBefore('#').uppercase() }
    val host = uri.host.orEmpty()
    val isCurrent = current?.id == url
    val accent = LocalNostrVaultColors.current.primary
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Color.White.copy(alpha = 0.06f)).padding(10.dp),
    ) {
        Box(
            Modifier.size(52.dp).clip(RoundedCornerShape(8.dp)).background(accent.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Filled.GraphicEq, contentDescription = null, tint = accent, modifier = Modifier.size(26.dp))
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(title, color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (host.isNotEmpty()) Text(host, color = SecondaryText, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text("♪ $ext", color = SecondaryText, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
        }
        IconButton(
            onClick = {
                if (isCurrent) MusicPlayer.togglePlayPause()
                else MusicPlayer.playTracks(listOf(PlayerTrack(id = url, title = title, artist = host, artworkUrl = null, audioUrl = url, durationSec = null)))
            },
            modifier = Modifier.size(48.dp),
        ) {
            Icon(
                if (isCurrent && playing) Icons.Filled.PauseCircle else Icons.Filled.PlayCircle,
                contentDescription = if (isCurrent && playing) "Pause $title" else "Play $title",
                tint = accent, modifier = Modifier.size(40.dp),
            )
        }
    }
}
