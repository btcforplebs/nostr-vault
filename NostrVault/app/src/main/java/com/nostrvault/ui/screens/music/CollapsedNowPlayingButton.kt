package com.nostrvault.ui.screens.music

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
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
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.unit.dp
import com.nostrvault.service.music.MusicPlayer
import com.nostrvault.ui.theme.LocalNostrVaultColors

/**
 * The folded bar's stand-in for the mini player: the cover as a small disc
 * with play/pause on it and the song's progress around its edge (a steady red
 * ring for a live stream). Tap plays or pauses; hold offers Open player (or
 * the minimized live stream) and Go to the artist or album.
 * Nothing at all when nothing is loaded, so the folded bar is unchanged
 * without music. iOS: CollapsedNowPlayingButton.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun CollapsedNowPlayingButton(actions: MusicActions) {
    val track by MusicPlayer.current.collectAsState()
    val playing by MusicPlayer.isPlaying.collectAsState()
    val buffering by MusicPlayer.isBuffering.collectAsState()
    val position by MusicPlayer.positionMs.collectAsState()
    val duration by MusicPlayer.durationMs.collectAsState()
    val liveStream by MusicPlayer.liveStream.collectAsState()
    var showFull by remember { mutableStateOf(false) }
    val t = track ?: return
    val minimizedStream = liveStream?.takeIf { t.isLive }
    val progress = if (!t.isLive && duration > 0) (position.toFloat() / duration).coerceIn(0f, 1f) else 0f
    val accent = LocalNostrVaultColors.current.primary
    var menu by remember { mutableStateOf(false) }
    val openPlayer = {
        if (minimizedStream != null) {
            com.nostrvault.ui.components.LiveStreamRouter.open(minimizedStream)
        } else {
            showFull = true
        }
    }

    Box {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .size(36.dp)
                .clip(CircleShape)
                .combinedClickable(
                    onClickLabel = if (playing) "Pause" else "Play",
                    onLongClickLabel = "More",
                    onClick = MusicPlayer::togglePlayPause,
                    onLongClick = { menu = true },
                )
                .semantics {
                    stateDescription = "${t.title}, ${t.artist}"
                    customActions = listOf(CustomAccessibilityAction("Open player") { openPlayer(); true })
                },
        ) {
            Artwork(t.artworkUrl, 36.dp, CircleShape)
            Box(Modifier.matchParentSize().background(Color.Black.copy(alpha = 0.45f)))
            if (buffering && playing) {
                CircularProgressIndicator(Modifier.size(14.dp), color = Color.White, strokeWidth = 1.5.dp)
            } else {
                Icon(
                    if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                    contentDescription = null,
                    tint = Color.White,
                    modifier = Modifier.size(16.dp),
                )
            }
            androidx.compose.foundation.Canvas(Modifier.matchParentSize()) {
                val stroke = 2.dp.toPx()
                val inset = stroke / 2
                val arcSize = androidx.compose.ui.geometry.Size(size.width - stroke, size.height - stroke)
                val topLeft = androidx.compose.ui.geometry.Offset(inset, inset)
                drawCircle(
                    color = if (t.isLive) Color.Red.copy(alpha = 0.8f) else Color.White.copy(alpha = 0.2f),
                    radius = (size.minDimension - stroke) / 2,
                    style = androidx.compose.ui.graphics.drawscope.Stroke(stroke),
                )
                if (progress > 0f) drawArc(
                    color = accent,
                    startAngle = -90f,
                    sweepAngle = 360f * progress,
                    useCenter = false,
                    topLeft = topLeft,
                    size = arcSize,
                    style = androidx.compose.ui.graphics.drawscope.Stroke(stroke, cap = androidx.compose.ui.graphics.StrokeCap.Round),
                )
            }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            MusicNowPlayingMenuItems(t, openPlayer = openPlayer) { menu = false }
        }
    }
    if (showFull) NowPlayingSheet(actions = actions, onDismiss = { showFull = false })
}
