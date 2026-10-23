package com.nostrvault.ui.screens.music

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
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
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.service.music.MusicPlayer
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText

// ── Mini player ─────────────────────────────────────────────────

/**
 * Sits above the bottom bar on every tab while a song or live stream is
 * loaded: artwork, title, play/pause, next and ✕, with a thin progress line.
 * Tap it for the full player, or, for a minimized live stream, to pop the
 * stream's own window back out (video, chat and all). iOS: MiniPlayerBar,
 * PlayerSheet.
 */
@Composable
fun MiniPlayerBar(actions: MusicActions, modifier: Modifier = Modifier) {
    val track by MusicPlayer.current.collectAsState()
    val playing by MusicPlayer.isPlaying.collectAsState()
    val buffering by MusicPlayer.isBuffering.collectAsState()
    val hasNext by MusicPlayer.hasNext.collectAsState()
    val position by MusicPlayer.positionMs.collectAsState()
    val duration by MusicPlayer.durationMs.collectAsState()
    val liveStream by MusicPlayer.liveStream.collectAsState()
    var showFull by remember { mutableStateOf(false) }
    val t = track ?: return
    val minimizedStream = liveStream?.takeIf { t.isLive }
    // While the stream's own window is up it has the picture (and covers this).
    val windowOpen by com.nostrvault.ui.components.LiveStreamRouter.playing.collectAsState()
    val livePlayer = minimizedStream?.takeIf { windowOpen == null }?.let { MusicPlayer.livePlayer(it.address) }
    // Minimized, the stream plays sound only: decoding its picture for the
    // corner made the feed unscrollable on the Moto (Logen, 2026-10-23). The
    // video track is switched off, so nothing is decoded; the stream window
    // switches it back on when it takes the stream back (LiveStreamScreen).
    LaunchedEffect(livePlayer) {
        val p = livePlayer ?: return@LaunchedEffect
        p.trackSelectionParameters = p.trackSelectionParameters.buildUpon()
            .setTrackTypeDisabled(androidx.media3.common.C.TRACK_TYPE_VIDEO, true)
            .build()
    }

    Box(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp)
            .height(com.nostrvault.ui.navigation.FloatingButtonRow.miniPlayerHeight)
            .clip(RoundedCornerShape(26.dp))
            .background(Color(0xFF1E1E22).copy(alpha = 0.96f))
            .border(1.dp, Color.White.copy(alpha = 0.12f), RoundedCornerShape(26.dp))
            .clickable(onClickLabel = if (minimizedStream != null) "Open the live stream" else "Open the player") {
                if (minimizedStream != null) {
                    com.nostrvault.ui.components.LiveStreamRouter.open(minimizedStream)
                } else {
                    showFull = true
                }
            },
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxSize().padding(start = 6.dp)) {
            Box(Modifier.size(40.dp).clip(CircleShape)) {
                // A live stream shows its still image here, not its picture
                // (see the video track above).
                Artwork(t.artworkUrl, 40.dp, CircleShape)
            }
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
            // Sharing the row with a floating button leaves no room for skip;
            // play and ✕ stay, and skip lives in the full player. iOS: compact.
            if (!t.isLive && com.nostrvault.ui.navigation.FloatingButtonRow.reservedWidth == 0.dp) {
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
