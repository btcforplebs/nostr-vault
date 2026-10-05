package com.nostrvault.ui.components

import android.content.Context
import android.net.Uri
import android.view.TextureView
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.AspectRatioFrameLayout
import com.nostrvault.ui.theme.NostrVaultIcons
import kotlinx.coroutines.delay
import java.util.Collections
import kotlin.math.roundToInt

/**
 * Which feed video may play inline. Each candidate reports how much of it is on
 * screen; the most visible one past [AUTOPLAY_MIN_VISIBLE] plays and every
 * other shows its poster. One player at a time, whatever the scroll, so a
 * low-RAM phone never holds a decoder per card. iOS InlineFeedVideoPlayer.
 */
internal object FeedVideoAutoplay {
    private val visible = mutableStateMapOf<MediaSourceKey, Float>()

    /** URLs that failed to play this session; they stay on their poster. */
    val failed: MutableSet<String> = Collections.synchronizedSet(mutableSetOf())

    /** Read inside composition, so a change of winner recomposes its readers. */
    val active: MediaSourceKey? get() = pickAutoplay(visible)

    fun report(key: MediaSourceKey, fraction: Float) {
        // Tenths: a scroll moves the fraction every frame, and each write
        // re-runs the pick for every card that is reading it.
        val q = (fraction.coerceIn(0f, 1f) * 10).roundToInt() / 10f
        if (q <= 0f) visible.remove(key) else if (visible[key] != q) visible[key] = q
    }

    fun remove(key: MediaSourceKey) {
        visible.remove(key)
    }
}

/** Below this share on screen a video does not start. */
internal const val AUTOPLAY_MIN_VISIBLE = 0.6f

/**
 * The candidate to play: the most visible at or above [threshold]. A tie goes
 * to the one reported first, so two equal cards don't trade the player back
 * and forth.
 */
internal fun <K> pickAutoplay(fractions: Map<K, Float>, threshold: Float = AUTOPLAY_MIN_VISIBLE): K? {
    var best: K? = null
    var bestFraction = 0f
    for ((key, fraction) in fractions) {
        if (fraction >= threshold && fraction > bestFraction) {
            best = key
            bestFraction = fraction
        }
    }
    return best
}

/**
 * A feed video playing in place: muted and looping while it is the most
 * visible one, paused (and its player released) when it scrolls away, the app
 * leaves the foreground, the screen is navigated away from, or the full-screen
 * viewer opens. Drawn over the poster [content] the caller already shows, so
 * nothing moves when the first frame lands. The speaker button toggles sound;
 * a tap anywhere else falls through to the caller (it opens the viewer).
 */
@Composable
internal fun InlineFeedVideo(
    key: MediaSourceKey,
    url: String,
    modifier: Modifier = Modifier,
) {
    DisposableEffect(key) { onDispose { FeedVideoAutoplay.remove(key) } }
    val isWinner by remember(key) { derivedStateOf { FeedVideoAutoplay.active == key } }
    val viewerOpen = FullScreenMediaRouter.request.collectAsState().value != null
    val lifecycle by LocalLifecycleOwner.current.lifecycle.currentStateAsState()
    val resumed = lifecycle.isAtLeast(Lifecycle.State.RESUMED)
    var failed by remember(url) { mutableStateOf(url in FeedVideoAutoplay.failed) }

    // Fast flings never build a player: it has to stay the winner a moment.
    var settled by remember(key) { mutableStateOf(false) }
    val wantsToPlay = isWinner && !viewerOpen && resumed && !failed
    LaunchedEffect(wantsToPlay) {
        settled = false
        if (wantsToPlay) {
            delay(300)
            settled = true
        }
    }

    Box(
        modifier = modifier.onGloballyPositioned { coords ->
            val height = coords.size.height
            val fraction = if (height > 0) coords.boundsInWindow().height / height else 0f
            FeedVideoAutoplay.report(key, fraction)
        },
    ) {
        if (wantsToPlay && settled) {
            ActiveInlineVideo(
                url = url,
                onFailed = {
                    FeedVideoAutoplay.failed.add(url)
                    failed = true
                },
            )
        } else {
            PlayBadge(Modifier.align(Alignment.Center))
        }
    }
}

@Composable
private fun PlayBadge(modifier: Modifier) {
    Icon(
        imageVector = NostrVaultIcons.PlayCircle,
        contentDescription = "Video",
        tint = Color.White.copy(alpha = 0.85f),
        modifier = modifier.size(32.dp),
    )
}

/** The one live player. Leaving composition releases it. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
@Composable
private fun ActiveInlineVideo(url: String, onFailed: () -> Unit) {
    val context = LocalContext.current
    val player = remember(url) { buildInlinePlayer(context, url) }
    var muted by remember(url) { mutableStateOf(true) }
    var hasFrame by remember(url) { mutableStateOf(false) }
    var aspect by remember(url) { mutableStateOf(0f) }

    DisposableEffect(player) {
        val listener = object : Player.Listener {
            override fun onRenderedFirstFrame() {
                hasFrame = true
            }

            override fun onVideoSizeChanged(videoSize: VideoSize) {
                if (videoSize.width > 0 && videoSize.height > 0) {
                    aspect = videoSize.width * videoSize.pixelWidthHeightRatio / videoSize.height
                }
            }

            override fun onPlayerError(error: PlaybackException) {
                onFailed()
            }
        }
        player.addListener(listener)
        onDispose {
            player.removeListener(listener)
            player.release()
        }
    }

    Box(Modifier.fillMaxSize()) {
        // A TextureView, not PlayerView's SurfaceView: a SurfaceView ignores
        // the card's rounded clip and trails the list by a frame as it scrolls.
        AndroidView(
            factory = { ctx ->
                AspectRatioFrameLayout(ctx).apply {
                    resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
                    val texture = TextureView(ctx)
                    addView(
                        texture,
                        FrameLayout.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT,
                            ViewGroup.LayoutParams.MATCH_PARENT,
                        ),
                    )
                    player.setVideoTextureView(texture)
                }
            },
            update = { frame -> if (aspect > 0f) frame.setAspectRatio(aspect) },
            // The poster underneath stays until there is a frame to replace it.
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer { alpha = if (hasFrame) 1f else 0f },
        )
        if (!hasFrame) PlayBadge(Modifier.align(Alignment.Center))

        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(8.dp)
                .size(30.dp)
                .clip(CircleShape)
                .background(Color.Black.copy(alpha = 0.6f))
                .clickable(onClickLabel = if (muted) "Unmute" else "Mute") {
                    muted = !muted
                    player.volume = if (muted) 0f else 1f
                    // Sound takes audio focus (pausing the mini player); a
                    // muted video never does.
                    player.claimSound(!muted)
                },
        ) {
            Icon(
                imageVector = if (muted) NostrVaultIcons.VolumeOff else NostrVaultIcons.VolumeUp,
                contentDescription = if (muted) "Unmute" else "Mute",
                tint = Color.White,
                modifier = Modifier.size(15.dp),
            )
        }
    }
}

/**
 * A muted, looping player with a small buffer: a feed preview needs a few
 * seconds ahead, not the default fifty, and memory is what a low-end phone is
 * short of.
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
private fun buildInlinePlayer(context: Context, url: String): ExoPlayer =
    ExoPlayer.Builder(context)
        .setLoadControl(
            DefaultLoadControl.Builder()
                .setBufferDurationsMs(2_000, 8_000, 1_000, 1_000)
                .build(),
        )
        .build()
        .apply {
            setMediaItem(MediaItem.fromUri(Uri.parse(url)))
            repeatMode = Player.REPEAT_MODE_ALL
            volume = 0f
            claimSound(false)
            playWhenReady = true
            prepare()
        }
