package com.nostrvault.ui.components

import android.content.Context
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.media3.common.Player
import com.nostrvault.service.music.MusicPlayer
import com.nostrvault.service.music.PlayerTrack
import com.nostrvault.ui.theme.Motion
import com.nostrvault.ui.theme.NostrVaultIcons
import dagger.hilt.android.EntryPointAccessors
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Minimize for a full-screen video, the way a live stream minimizes: the clip
 * carries on as sound in the mini player, and a tap on the bar opens it again
 * here, on the mini player's own player, at the bar's time. iOS: a video item
 * in MusicPlayerService with FeedMediaViewer's sharedPlayer.
 */

/**
 * What a viewer passes to [VideoPlayer] to offer Minimize. [authorPubkey] names
 * the mini player's "artist" and art; [onMinimized] closes the viewer once the
 * bar has the clip. A locked DM video never offers it: it plays from bytes in
 * memory, which the music service cannot read.
 */
class VideoMinimize(
    val authorPubkey: String?,
    val onMinimized: () -> Unit,
)

/** Whether the minimized clip's viewer is up. The mini bar opens it. */
object SharedVideoRouter {
    private val _open = MutableStateFlow(false)
    val open = _open.asStateFlow()

    fun open() { _open.value = true }

    fun close() { _open.value = false }
}

/**
 * The viewer's Minimize: its own player pauses first, so the sound never
 * plays twice, then the mini player takes the clip from [player]'s position.
 * [uri] is what the viewer is actually playing (a blossom link's checked file,
 * say), not the note's link. The viewer releases its player as it closes.
 */
internal fun minimizeToBar(context: Context, player: Player, uri: String, minimize: VideoMinimize) {
    val positionMs = player.currentPosition.coerceAtLeast(0)
    player.pause()
    val profile = minimize.authorPubkey?.let { pk ->
        runCatching {
            EntryPointAccessors.fromApplication(context.applicationContext, LiveEmbedEntryPoint::class.java)
                .nostrService().profiles.value[pk]
        }.getOrNull()
    }
    MusicPlayer.playVideo(
        PlayerTrack(
            id = PlayerTrack.videoId(uri),
            title = "Video",
            artist = profile?.bestName ?: minimize.authorPubkey?.let { "npub…" + it.takeLast(6) } ?: "Your vault",
            artworkUrl = profile?.pictureURL,
            audioUrl = uri,
            durationSec = player.duration.takeIf { it > 0 }?.let { (it / 1000).toInt() },
            hostPubkey = minimize.authorPubkey,
            isVideo = true,
        ),
        positionMs,
    )
    minimize.onMinimized()
}

/** The chevron that minimizes, as on the live stream. */
@Composable
internal fun MinimizeVideoButton(onClick: () -> Unit) {
    IconButton(onClick = onClick, modifier = Modifier.size(40.dp)) {
        Icon(
            imageVector = NostrVaultIcons.ChevronDown,
            contentDescription = "Minimize",
            tint = Color.White,
            modifier = Modifier.size(22.dp),
        )
    }
}

/** Over the whole app while [SharedVideoRouter] is open and the mini player has a clip. */
@Composable
fun SharedVideoHost() {
    val open by SharedVideoRouter.open.collectAsState()
    val track by MusicPlayer.current.collectAsState()
    if (!open) return
    // The clip ended or was stopped: nothing to show.
    val player = if (track?.isVideo == true) MusicPlayer.videoPlayer() else null
    if (player == null) {
        LaunchedEffect(Unit) { SharedVideoRouter.close() }
        return
    }
    BackHandler { SharedVideoRouter.close() }
    SharedVideoPlayer(player = player, onMinimize = { SharedVideoRouter.close() })
}

/**
 * The minimized clip full screen again: the mini player's own player, with its
 * picture back on, so the sound carries on at the bar's time with no second
 * copy and no re-download. Minimize (or Back) hands it back to the bar as
 * sound only.
 */
@Composable
private fun SharedVideoPlayer(player: Player, onMinimize: () -> Unit) {
    var isPlaying by remember { mutableStateOf(player.isPlaying) }
    var positionMs by remember { mutableLongStateOf(player.currentPosition.coerceAtLeast(0)) }
    var durationMs by remember { mutableLongStateOf(player.duration.coerceAtLeast(0)) }
    var progress by remember { mutableFloatStateOf(0f) }
    var isSeeking by remember { mutableStateOf(false) }
    var showControls by remember { mutableStateOf(true) }
    var interactionEpoch by remember { mutableIntStateOf(0) }

    // The bar played sound only; here the picture comes back, and goes again
    // as the viewer closes or the app leaves the screen (MiniPlayerBar's rule
    // for the Moto: no picture decoded behind the feed).
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(player, lifecycleOwner) {
        player.setSoundOnly(false)
        if (!player.playWhenReady && player.playbackState != Player.STATE_ENDED) {
            if (player.playbackState == Player.STATE_IDLE) player.prepare()
            player.play()
        }
        val listener = object : Player.Listener {
            override fun onIsPlayingChanged(playing: Boolean) { isPlaying = playing }
        }
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_STOP -> player.setSoundOnly(true)
                Lifecycle.Event.ON_START -> player.setSoundOnly(false)
                else -> Unit
            }
        }
        player.addListener(listener)
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            player.removeListener(listener)
            player.setSoundOnly(true)
        }
    }

    LaunchedEffect(isPlaying, isSeeking) {
        do {
            if (!isSeeking) {
                durationMs = player.duration.takeIf { it > 0 } ?: 0L
                positionMs = player.currentPosition.coerceAtLeast(0L)
                progress = if (durationMs > 0) positionMs.toFloat() / durationMs else 0f
            }
            delay(250)
        } while (isPlaying)
    }

    LaunchedEffect(showControls, isPlaying, interactionEpoch) {
        if (showControls && isPlaying && !isSeeking) {
            delay(3000)
            showControls = false
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black)
            .clickable(indication = null, interactionSource = remember { MutableInteractionSource() }) {
                showControls = !showControls
            },
    ) {
        VideoSurface(player = player, modifier = Modifier.fillMaxSize())

        AnimatedVisibility(
            visible = showControls,
            enter = fadeIn(Motion.fade()),
            exit = fadeOut(Motion.fade()),
            modifier = Modifier.align(Alignment.TopStart),
        ) {
            Box(
                Modifier
                    .statusBarsPadding()
                    .padding(8.dp)
                    .background(Color.Black.copy(alpha = 0.4f), CircleShape),
            ) { MinimizeVideoButton(onClick = onMinimize) }
        }

        AnimatedVisibility(
            visible = showControls,
            enter = fadeIn(Motion.fade()),
            exit = fadeOut(Motion.fade()),
            modifier = Modifier.align(Alignment.BottomCenter),
        ) {
            Box(Modifier.fillMaxWidth()) {
                Box(
                    Modifier
                        .matchParentSize()
                        .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.55f)))),
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
                            MusicPlayer.togglePlayPause()
                        },
                        modifier = Modifier.size(40.dp),
                    ) {
                        Icon(
                            imageVector = if (isPlaying) NostrVaultIcons.PauseIcon else NostrVaultIcons.PlayArrow,
                            contentDescription = if (isPlaying) "Pause" else "Play",
                            tint = Color.White,
                            modifier = Modifier.size(24.dp),
                        )
                    }
                    Text(clipTime(positionMs), color = Color.White.copy(alpha = 0.85f), fontSize = 12.sp, fontFamily = FontFamily.Monospace)
                    ThinSeekBar(
                        progress = progress,
                        onSeekStart = {
                            isSeeking = true
                            interactionEpoch++
                        },
                        onSeek = { fraction ->
                            progress = fraction
                            val target = (fraction * durationMs.coerceAtLeast(1L)).toLong()
                            player.seekTo(target)
                            positionMs = target
                        },
                        onSeekEnd = { isSeeking = false },
                        modifier = Modifier.weight(1f).padding(horizontal = 6.dp),
                    )
                    Text(clipTime(durationMs), color = Color.White.copy(alpha = 0.85f), fontSize = 12.sp, fontFamily = FontFamily.Monospace)
                }
            }
        }
    }
}

private fun clipTime(ms: Long): String {
    if (ms <= 0) return "0:00"
    val s = ms / 1000
    return "%d:%02d".format(s / 60, s % 60)
}
