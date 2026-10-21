package com.nostrvault.ui.screens.music

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
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
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText

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
    val liveStream by MusicPlayer.liveStream.collectAsState()
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
                // The video back: the player takes the sound, so this pauses.
                liveStream?.let { stream ->
                    AssistChip(onClick = { onDismiss(); com.nostrvault.ui.components.LiveStreamRouter.open(stream) }, label = { Text("Watch") },
                        leadingIcon = { Icon(Icons.Filled.OndemandVideo, null) })
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
                TextButton(onClick = { runCatching { ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(page))) } }) {
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
