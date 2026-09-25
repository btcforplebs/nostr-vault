package com.nostrvault.ui.components

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.PackageManager
import android.net.Uri
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import com.nostrvault.MainActivity
import com.nostrvault.ui.theme.Motion
import com.nostrvault.ui.theme.NostrVaultIcons
import kotlinx.coroutines.delay

/**
 * Full-screen video player composable wrapping Media3 ExoPlayer.
 *
 * Features:
 * - Auto-play with looping (matches iOS FullScreenVideoPlayer behaviour)
 * - Tap to toggle the control rail; auto-hides after 3s while playing
 * - Bottom rail: play/pause · elapsed · scrubber · duration · mute · PiP
 *   (same layout as the iOS VideoControlBar)
 * - Picture-in-Picture: registers with [VideoPiPBridge] so MainActivity can
 *   auto-enter PiP on home-press; the rail's PiP button enters it on demand.
 *   All chrome hides while in PiP.
 * - Proper lifecycle management (releases player on dispose)
 */
@OptIn(ExperimentalMaterial3Api::class)
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
@Composable
fun VideoPlayer(
    uri: String,
    modifier: Modifier = Modifier,
    autoplay: Boolean = true,
) {
    val context = LocalContext.current
    val isInPiP by VideoPiPBridge.isInPiP.collectAsState()
    val supportsPiP = remember {
        context.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
    }

    var isPlaying by remember { mutableStateOf(autoplay) }
    var isMuted by remember { mutableStateOf(false) }
    var progress by remember { mutableFloatStateOf(0f) }
    var positionMs by remember { mutableLongStateOf(0L) }
    var durationMs by remember { mutableLongStateOf(0L) }
    var isSeeking by remember { mutableStateOf(false) }
    var showControls by remember { mutableStateOf(true) }
    // Bumped on every control interaction to restart the auto-hide countdown
    var interactionEpoch by remember { mutableIntStateOf(0) }

    val exoPlayer = remember { buildLoopingExoPlayer(context, uri, playWhenReady = autoplay) }

    // Listen to player state changes, register for PiP, and release on dispose
    DisposableEffect(exoPlayer) {
        val listener = object : Player.Listener {
            override fun onIsPlayingChanged(playing: Boolean) {
                isPlaying = playing
            }

            override fun onVideoSizeChanged(videoSize: VideoSize) {
                VideoPiPBridge.updateAspectRatio(videoSize.width, videoSize.height)
            }
        }
        exoPlayer.addListener(listener)
        VideoPiPBridge.setActive(exoPlayer)
        onDispose {
            VideoPiPBridge.clearActive(exoPlayer)
            exoPlayer.removeListener(listener)
            exoPlayer.release()
        }
    }

    // Poll progress ~4 times per second while playing (skip updates during seek)
    LaunchedEffect(isPlaying, isSeeking) {
        while (isPlaying && !isSeeking) {
            durationMs = exoPlayer.duration.takeIf { it > 0 } ?: 0L
            positionMs = exoPlayer.currentPosition.coerceAtLeast(0L)
            progress = if (durationMs > 0) positionMs.toFloat() / durationMs else 0f
            delay(250)
        }
    }

    // Auto-hide controls after 3 seconds; any interaction restarts the countdown
    LaunchedEffect(showControls, isPlaying, interactionEpoch) {
        if (showControls && isPlaying && !isSeeking) {
            delay(3000)
            showControls = false
        }
    }

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(Color.Black)
            .clickable(
                indication = null,
                interactionSource = remember { MutableInteractionSource() },
            ) {
                if (!isInPiP) showControls = !showControls
            },
    ) {
        // Video surface
        VideoSurface(player = exoPlayer, modifier = Modifier.fillMaxSize())

        // Control rail overlay (never shown while the activity is in a PiP window)
        AnimatedVisibility(
            visible = showControls && !isInPiP,
            enter = fadeIn(Motion.fade()),
            exit = fadeOut(Motion.fade()),
            modifier = Modifier.align(Alignment.BottomCenter),
        ) {
            Box(modifier = Modifier.fillMaxWidth()) {
                // Soft scrim so white controls read on bright footage
                Box(
                    modifier = Modifier
                        .matchParentSize()
                        .background(
                            Brush.verticalGradient(
                                listOf(Color.Transparent, Color.Black.copy(alpha = 0.55f)),
                            ),
                        ),
                )

                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                    modifier = Modifier
                        .fillMaxWidth()
                        .navigationBarsPadding()
                        .padding(horizontal = 8.dp, vertical = 6.dp),
                ) {
                    IconButton(
                        onClick = {
                            interactionEpoch++
                            if (exoPlayer.isPlaying) exoPlayer.pause() else exoPlayer.play()
                        },
                        modifier = Modifier.size(40.dp),
                    ) {
                        Icon(
                            imageVector = if (isPlaying) NostrVaultIcons.PauseIcon
                                          else NostrVaultIcons.PlayArrow,
                            contentDescription = if (isPlaying) "Pause" else "Play",
                            tint = Color.White,
                            modifier = Modifier.size(24.dp),
                        )
                    }

                    Text(
                        text = formatPlayerTime(positionMs),
                        color = Color.White.copy(alpha = 0.85f),
                        fontSize = 12.sp,
                        fontFamily = FontFamily.Monospace,
                    )

                    ThinSeekBar(
                        progress = progress,
                        onSeekStart = {
                            isSeeking = true
                            interactionEpoch++
                        },
                        onSeek = { fraction ->
                            progress = fraction
                            val duration = exoPlayer.duration.coerceAtLeast(1L)
                            exoPlayer.seekTo((fraction * duration).toLong())
                            positionMs = (fraction * duration).toLong()
                        },
                        onSeekEnd = { isSeeking = false },
                        modifier = Modifier
                            .weight(1f)
                            .padding(horizontal = 6.dp),
                    )

                    Text(
                        text = formatPlayerTime(durationMs),
                        color = Color.White.copy(alpha = 0.85f),
                        fontSize = 12.sp,
                        fontFamily = FontFamily.Monospace,
                    )

                    IconButton(
                        onClick = {
                            interactionEpoch++
                            isMuted = !isMuted
                            exoPlayer.volume = if (isMuted) 0f else 1f
                        },
                        modifier = Modifier.size(40.dp),
                    ) {
                        Icon(
                            imageVector = if (isMuted) NostrVaultIcons.VolumeOff
                                          else NostrVaultIcons.VolumeUp,
                            contentDescription = if (isMuted) "Unmute" else "Mute",
                            tint = Color.White,
                            modifier = Modifier.size(20.dp),
                        )
                    }

                    if (supportsPiP) {
                        IconButton(
                            onClick = {
                                (context.findActivity() as? MainActivity)?.enterVideoPiP()
                            },
                            modifier = Modifier.size(40.dp),
                        ) {
                            Icon(
                                imageVector = NostrVaultIcons.PictureInPicture,
                                contentDescription = "Picture in picture",
                                tint = Color.White,
                                modifier = Modifier.size(20.dp),
                            )
                        }
                    }
                }
            }
        }
    }
}

/**
 * Hairline capsule scrubber — 3dp track that thickens to 6dp under a drag,
 * matching the iOS VideoScrubber. Tap or drag anywhere on its (tall) hit
 * area to seek.
 */
@Composable
internal fun ThinSeekBar(
    progress: Float,
    onSeekStart: () -> Unit,
    onSeek: (Float) -> Unit,
    onSeekEnd: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var dragging by remember { mutableStateOf(false) }
    val trackHeight by animateDpAsState(
        targetValue = if (dragging) 6.dp else 3.dp,
        animationSpec = Motion.control(),
        label = "seekbar-height",
    )

    BoxWithConstraints(
        contentAlignment = Alignment.CenterStart,
        modifier = modifier
            .height(32.dp)
            .pointerInput(Unit) {
                detectTapGestures { offset ->
                    onSeekStart()
                    onSeek((offset.x / size.width).coerceIn(0f, 1f))
                    onSeekEnd()
                }
            }
            .pointerInput(Unit) {
                detectHorizontalDragGestures(
                    onDragStart = { offset ->
                        dragging = true
                        onSeekStart()
                        onSeek((offset.x / size.width).coerceIn(0f, 1f))
                    },
                    onDragEnd = {
                        dragging = false
                        onSeekEnd()
                    },
                    onDragCancel = {
                        dragging = false
                        onSeekEnd()
                    },
                ) { change, _ ->
                    change.consume()
                    onSeek((change.position.x / size.width).coerceIn(0f, 1f))
                }
            },
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(trackHeight)
                .background(Color.White.copy(alpha = 0.3f), RoundedCornerShape(50)),
        )
        Box(
            modifier = Modifier
                .width(maxWidth * progress.coerceIn(0f, 1f))
                .height(trackHeight)
                .background(Color.White.copy(alpha = 0.85f), RoundedCornerShape(50)),
        )
    }
}

/**
 * A looping ExoPlayer for one video URL — the one build every video surface in
 * the app shares (the full-screen player and the Reels pages). The caller owns
 * it and must [ExoPlayer.release] it.
 */
internal fun buildLoopingExoPlayer(
    context: Context,
    uri: String,
    playWhenReady: Boolean,
    /** MIME from the event — lets an extensionless HLS link be opened as one. */
    mimeType: String? = null,
): ExoPlayer =
    ExoPlayer.Builder(context).build().apply {
        setMediaItem(
            MediaItem.Builder()
                .setUri(Uri.parse(uri))
                .apply { if (mimeType != null) setMimeType(mimeType) }
                .build(),
        )
        repeatMode = Player.REPEAT_MODE_ALL
        this.playWhenReady = playWhenReady
        prepare()
    }

/**
 * The bare video picture for [player]: no controller, a spinner while it
 * buffers. [resizeMode] is an [AspectRatioFrameLayout] mode — fit by default.
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
@Composable
internal fun VideoSurface(
    player: ExoPlayer,
    modifier: Modifier = Modifier,
    resizeMode: Int = AspectRatioFrameLayout.RESIZE_MODE_FIT,
) {
    AndroidView(
        factory = { ctx ->
            PlayerView(ctx).apply {
                useController = false
                setShowBuffering(PlayerView.SHOW_BUFFERING_WHEN_PLAYING)
            }
        },
        update = { view ->
            if (view.player !== player) view.player = player
            if (view.resizeMode != resizeMode) view.resizeMode = resizeMode
        },
        modifier = modifier,
    )
}

private fun formatPlayerTime(ms: Long): String {
    if (ms <= 0) return "0:00"
    val totalSeconds = ms / 1000
    return "%d:%02d".format(totalSeconds / 60, totalSeconds % 60)
}

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}
