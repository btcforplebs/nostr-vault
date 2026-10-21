package com.nostrvault.ui.screens.music

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.music.WavlakeLink
import com.nostrvault.service.music.MusicPlayer
import com.nostrvault.service.music.MusicRepeatMode
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.ui.draw.blur
import androidx.compose.ui.layout.ContentScale
import coil.compose.AsyncImage
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText

/**
 * Full player: the cover (or Up Next) over a blur of it, scrubber, shuffle /
 * previous / play / next / repeat, the song's pages and Share, then Up Next
 * and ⋯ along the bottom. iOS: NowPlayingView.
 */
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
    val liveStream by MusicPlayer.liveStream.collectAsState()
    var scrub by remember { mutableStateOf<Float?>(null) }
    var showingQueue by remember { mutableStateOf(false) }
    val t = track
    LaunchedEffect(t) { if (t == null) onDismiss() }
    if (t == null) return
    // Closes the player and opens the page in the Music feed.
    val go: (MusicPage) -> Unit = { page -> onDismiss(); MusicFeedState.reveal(page) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = MaterialTheme.colorScheme.surface,
        dragHandle = null,
    ) {
        Box(Modifier.fillMaxWidth()) {
            NowPlayingBackdrop(t.artworkUrl, Modifier.matchParentSize())
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 16.dp),
            ) {
                Box(
                    Modifier.padding(top = 10.dp, bottom = 18.dp).size(width = 40.dp, height = 5.dp).clip(CircleShape)
                        .background(SecondaryText.copy(alpha = 0.4f)),
                )
                // Up Next takes the artwork's place, so the controls stay put.
                Box(Modifier.height(280.dp).fillMaxWidth(), contentAlignment = Alignment.Center) {
                    if (showingQueue && !t.isLive) UpNextList(shuffled = shuffled, repeat = repeat)
                    else Artwork(t.artworkUrl, 280.dp, RoundedCornerShape(18.dp), shadow = 16.dp)
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
                // Where a song leads: its artist and album pages, and Share. A
                // live stream offers its video and host.
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.CenterHorizontally),
                    verticalArrangement = Arrangement.Center,
                ) {
                    val song = t.wavlake
                    val host = t.hostPubkey
                    if (song != null) {
                        MusicPage.artistOf(song)?.let { page -> NowPlayingActionButton("Artist", Icons.Filled.Mic) { go(page) } }
                        MusicPage.albumOf(song)?.let { page -> NowPlayingActionButton("Album", NostrVaultIcons.Layers) { go(page) } }
                        NowPlayingActionButton("Share", NostrVaultIcons.Share) { onDismiss(); actions.onShare(WavlakeLink.shareText(song)) }
                    } else if (host != null) {
                        // The video back: the player takes the sound, so this pauses.
                        liveStream?.let { stream ->
                            NowPlayingActionButton("Watch", Icons.Filled.OndemandVideo) {
                                onDismiss(); com.nostrvault.ui.components.LiveStreamRouter.open(stream)
                            }
                        }
                        NowPlayingActionButton("Host", NostrVaultIcons.AccountCircle) { onDismiss(); actions.onOpenProfile(host) }
                    }
                }
                Spacer(Modifier.height(24.dp))
                // Up Next and the song's other actions. The output picker iOS
                // has on the left isn't on Android yet; its place stays so Up
                // Next sits in the middle.
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp)) {
                    Spacer(Modifier.size(44.dp))
                    Spacer(Modifier.weight(1f))
                    if (!t.isLive) {
                        MusicModeButton(
                            icon = Icons.AutoMirrored.Filled.List, isOn = showingQueue, label = "Up Next",
                            value = if (showingQueue) "Showing" else "Hidden", onClick = { showingQueue = !showingQueue },
                        )
                        Spacer(Modifier.weight(1f))
                    }
                    val song = t.wavlake
                    if (song != null) {
                        var more by remember { mutableStateOf(false) }
                        Box(Modifier.size(44.dp), contentAlignment = Alignment.Center) {
                            MusicMoreButton("More for ${song.title}") { more = true }
                            DropdownMenu(expanded = more, onDismissRequest = { more = false }) {
                                // Artist and Album are buttons right above.
                                MusicTrackMenuItems(song, actions, opensPages = false) { more = false; onDismiss() }
                            }
                        }
                    } else {
                        Spacer(Modifier.size(44.dp))
                    }
                }
            }
        }
    }
}

/**
 * The cover, blown up and blurred under a scrim of the sheet's own colour,
 * so the player takes on the song's colours and text stays readable.
 * iOS: NowPlayingView.backdrop. (The blur needs Android 12; older phones
 * get the scrim over the cover.)
 */
@Composable
private fun NowPlayingBackdrop(url: String?, modifier: Modifier) {
    Box(modifier) {
        if (url != null) AsyncImage(
            model = url, contentDescription = null, contentScale = ContentScale.Crop,
            modifier = Modifier.matchParentSize().blur(50.dp).alpha(0.8f),
        )
        Box(Modifier.matchParentSize().background(MaterialTheme.colorScheme.surface.copy(alpha = 0.78f)))
    }
}

/** A plain grey capsule: icon and title. iOS: NowPlayingView.actionButton. */
@Composable
private fun NowPlayingActionButton(title: String, icon: androidx.compose.ui.graphics.vector.ImageVector, onClick: () -> Unit) {
    val fill = MaterialTheme.colorScheme.onSurfaceVariant.let { it.copy(alpha = it.alpha * 0.15f) }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.clip(CircleShape).background(fill)
            .clickable(role = androidx.compose.ui.semantics.Role.Button, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 8.dp),
    ) {
        Icon(icon, contentDescription = null, tint = PrimaryText, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(6.dp))
        Text(title, color = PrimaryText, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
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
