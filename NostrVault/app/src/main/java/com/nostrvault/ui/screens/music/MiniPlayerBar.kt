package com.nostrvault.ui.screens.music

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.ui.draw.shadow
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
@OptIn(ExperimentalFoundationApi::class)
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

    var menu by remember { mutableStateOf(false) }
    val openPlayer = {
        if (minimizedStream != null) {
            com.nostrvault.ui.components.LiveStreamRouter.open(minimizedStream)
        } else {
            showFull = true
        }
    }
    val shape = RoundedCornerShape(26.dp)

    Box(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp)
            .height(com.nostrvault.ui.navigation.FloatingButtonRow.miniPlayerHeight)
            // A translucent surface with a soft shadow, as iOS's material
            // capsule: it follows the theme rather than a fixed dark grey.
            .shadow(8.dp, shape)
            .clip(shape)
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.92f))
            .border(1.dp, MaterialTheme.colorScheme.outlineVariant, shape)
            .combinedClickable(
                onClickLabel = if (minimizedStream != null) "Open the live stream" else "Open the player",
                onLongClickLabel = "More",
                onClick = openPlayer,
                onLongClick = { menu = true },
            ),
    ) {
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            MusicNowPlayingMenuItems(t, openPlayer = openPlayer) { menu = false }
        }
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxSize().padding(start = 6.dp)) {
            Box(Modifier.size(40.dp).clip(CircleShape)) {
                Artwork(t.artworkUrl, 40.dp, CircleShape)
                // A live stream shows its own picture, moving, over the
                // stream's image (which stays as the fallback until a frame
                // lands). iOS #305.
                livePlayer?.let { LiveArtworkVideo(it, Modifier.matchParentSize()) }
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

/**
 * [player]'s video, cropped to fill, in a TextureView (a SurfaceView would
 * ignore the round clip). Hidden until a frame is drawn, and the surface is
 * handed back on the way out so the stream window can take the picture.
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
@Composable
private fun LiveArtworkVideo(player: androidx.media3.common.Player, modifier: Modifier = Modifier) {
    var hasFrame by remember(player) { mutableStateOf(false) }
    var aspect by remember(player) {
        mutableFloatStateOf(player.videoSize.let { if (it.height > 0) it.width * it.pixelWidthHeightRatio / it.height else 0f })
    }
    DisposableEffect(player) {
        val listener = object : androidx.media3.common.Player.Listener {
            override fun onRenderedFirstFrame() { hasFrame = true }
            override fun onVideoSizeChanged(videoSize: androidx.media3.common.VideoSize) {
                if (videoSize.height > 0) aspect = videoSize.width * videoSize.pixelWidthHeightRatio / videoSize.height
            }
        }
        player.addListener(listener)
        onDispose { player.removeListener(listener) }
    }
    androidx.compose.ui.viewinterop.AndroidView(
        factory = { ctx ->
            androidx.media3.ui.AspectRatioFrameLayout(ctx).apply {
                resizeMode = androidx.media3.ui.AspectRatioFrameLayout.RESIZE_MODE_ZOOM
                val texture = android.view.TextureView(ctx)
                addView(
                    texture,
                    android.widget.FrameLayout.LayoutParams(
                        android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                        android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                    ),
                )
                player.setVideoTextureView(texture)
            }
        },
        update = { frame -> if (aspect > 0f) frame.setAspectRatio(aspect) },
        onRelease = { frame ->
            (frame.getChildAt(0) as? android.view.TextureView)?.let(player::clearVideoTextureView)
        },
        modifier = modifier.alpha(if (hasFrame) 1f else 0f),
    )
}

@Composable
fun LiveBadge() {
    Text(
        "LIVE", color = Color.White, fontSize = 10.sp, fontWeight = FontWeight.Black,
        modifier = Modifier.clip(RoundedCornerShape(50)).background(Color.Red).padding(horizontal = 5.dp, vertical = 1.dp),
    )
}
