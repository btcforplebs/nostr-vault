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
 * it; the mini player keeps going while you browse. iOS: MusicBrowserView.
 */
@Composable
fun MusicScreen(actions: MusicActions, contentPadding: PaddingValues) {
    val scope = rememberCoroutineScope()
    var query by remember { mutableStateOf("") }
    var trending by remember { mutableStateOf<List<WavlakeTrack>>(emptyList()) }
    var results by remember { mutableStateOf<List<WavlakeSearchResult>>(emptyList()) }
    var opened by remember { mutableStateOf<Pair<String, List<WavlakeTrack>>?>(null) }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var searchJob by remember { mutableStateOf<Job?>(null) }
    val current by MusicPlayer.current.collectAsState()
    val playing by MusicPlayer.isPlaying.collectAsState()

    suspend fun loadTrending() {
        loading = true; error = null
        trending = runCatching { WavlakeApi.trending() }.getOrElse { error = "Couldn't reach Wavlake. Tap to try again."; emptyList() }
        if (trending.isEmpty() && error == null) error = "Nothing trending right now."
        loading = false
    }

    fun open(title: String, load: suspend () -> List<WavlakeTrack>) {
        scope.launch {
            loading = true; error = null
            val tracks = runCatching { load() }.getOrDefault(emptyList())
            loading = false
            if (tracks.isEmpty()) error = "Couldn't load $title." else opened = title to tracks
        }
    }

    LaunchedEffect(Unit) { if (trending.isEmpty()) loadTrending() }

    // Search once typing pauses, so each keystroke isn't a request.
    LaunchedEffect(query) {
        searchJob?.cancel()
        opened = null
        val term = query.trim()
        if (term.isEmpty()) { results = emptyList(); error = null; loading = false; return@LaunchedEffect }
        delay(400)
        loading = true; error = null
        val found = runCatching { WavlakeApi.search(term) }.getOrDefault(emptyList())
        results = found
        loading = false
        if (found.isEmpty()) error = "No music found for \"$term\"."
    }

    val tracksOf: List<WavlakeTrack> = when {
        opened != null -> opened!!.second
        query.isNotBlank() -> results.filterIsInstance<WavlakeSearchResult.Track>().map { it.track }
        else -> trending
    }
    val collections = if (opened == null && query.isNotBlank()) results.filter { it !is WavlakeSearchResult.Track } else emptyList()

    LazyColumn(
        contentPadding = PaddingValues(
            start = 16.dp, end = 16.dp,
            top = contentPadding.calculateTopPadding() + 8.dp,
            bottom = contentPadding.calculateBottomPadding() + 140.dp,
        ),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        item(key = "search") {
            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                placeholder = { Text("Search songs, albums, artists") },
                leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                trailingIcon = {
                    if (query.isNotEmpty()) IconButton(onClick = { query = ""; opened = null }) {
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
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 8.dp)) {
                if (opened != null) {
                    TextButton(onClick = { opened = null }) { Text("‹ Back") }
                }
                Text(
                    text = opened?.first ?: if (query.isNotBlank()) "Songs" else "Trending on Wavlake",
                    color = PrimaryText, fontSize = 18.sp, fontWeight = FontWeight.Bold,
                )
            }
        }
        if (collections.isNotEmpty()) {
            item(key = "collections") {
                Column {
                    Text("Albums and artists", color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.height(8.dp))
                    LazyRow(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        items(collections, key = { it.key }) { result ->
                            when (result) {
                                is WavlakeSearchResult.Album -> CollectionTile(result.title, "Album", result.artUrl, RoundedCornerShape(10.dp)) {
                                    open(result.title) { WavlakeApi.album(result.id) }
                                }
                                is WavlakeSearchResult.Artist -> CollectionTile(result.name, "Artist", result.artUrl, CircleShape) {
                                    open(result.name) { WavlakeApi.artistTracks(result.id) }
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
                loading -> Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = LocalNostrVaultColors.current.primary)
                }
                error != null -> Text(
                    text = error!!, color = SecondaryText, fontSize = 14.sp,
                    modifier = Modifier.fillMaxWidth().padding(24.dp)
                        .clickable(enabled = query.isBlank() && opened == null) { scope.launch { loadTrending() } },
                )
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

@Composable
private fun CollectionTile(title: String, subtitle: String, art: String?, shape: Shape, onClick: () -> Unit) {
    Column(Modifier.width(110.dp).clickable(onClick = onClick)) {
        Artwork(art, 110.dp, shape)
        Text(title, color = PrimaryText, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
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
fun MusicTrackRow(track: WavlakeTrack, isCurrent: Boolean, isPlaying: Boolean, actions: MusicActions, onTap: () -> Unit) {
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
            Box(contentAlignment = Alignment.Center) {
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

/** Full player: big artwork, scrubber, previous / play / next, Share and Artist. */
@OptIn(ExperimentalMaterial3Api::class)
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
    val ctx = LocalContext.current
    val t = track
    LaunchedEffect(t) { if (t == null) onDismiss() }
    if (t == null) return

    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = Color(0xFF151518)) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 32.dp),
        ) {
            Artwork(t.artworkUrl, 280.dp, RoundedCornerShape(18.dp))
            Spacer(Modifier.height(20.dp))
            if (t.isLive) LiveBadge()
            Text(t.title, color = PrimaryText, fontSize = 22.sp, fontWeight = FontWeight.Bold)
            Text(t.artist, color = SecondaryText, fontSize = 16.sp)
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
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                t.wavlake?.let { song ->
                    AssistChip(onClick = { onDismiss(); actions.onShare(WavlakeLink.shareText(song)) }, label = { Text("Share") },
                        leadingIcon = { Icon(Icons.Filled.Share, null) })
                    song.artistNpub?.let(actions.npubToHex)?.let { hex ->
                        AssistChip(onClick = { onDismiss(); actions.onOpenProfile(hex) }, label = { Text("Artist") },
                            leadingIcon = { Icon(Icons.Filled.Person, null) })
                    }
                }
                t.hostPubkey?.let { host ->
                    AssistChip(onClick = { onDismiss(); actions.onOpenProfile(host) }, label = { Text("Host") },
                        leadingIcon = { Icon(Icons.Filled.Person, null) })
                }
            }
            t.pageUrl?.let { page ->
                TextButton(onClick = { ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(page))) }) {
                    Text(if (t.isLive) "Open stream" else "Open on Wavlake", color = SecondaryText)
                }
            }
        }
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
