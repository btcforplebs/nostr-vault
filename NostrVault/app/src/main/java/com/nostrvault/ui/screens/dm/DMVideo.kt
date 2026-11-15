package com.nostrvault.ui.screens.dm

import android.net.Uri
import android.webkit.MimeTypeMap
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import coil.decode.VideoFrameDecoder
import coil.request.ImageRequest

/**
 * Videos in DMs (Logen 2026-11-06): the photo button picks a video too, it
 * goes up through the same upload as a photo, and its link is sent in the
 * message (DMAttachment). Twin of iOS DMVideoAttachment.swift.
 */
internal object DMVideo {
    fun isVideoMime(type: String?): Boolean = type?.lowercase()?.startsWith("video/") == true

    /** The file extension a video's MIME type names, "mp4" when unknown. */
    fun extension(mime: String): String =
        MimeTypeMap.getSingleton().getExtensionFromMimeType(mime.lowercase())
            ?: if (mime.lowercase() == "video/quicktime") "mov" else "mp4"
}

/** A video a message carries: a play tile; a tap opens the viewer, which plays it. */
@Composable
internal fun DMVideoTile(size: Dp, onClick: () -> Unit) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .size(size)
            .background(Color.Black.copy(alpha = 0.85f))
            .clickable(onClick = onClick)
            .semantics { contentDescription = "Video" },
    ) {
        Icon(Icons.Filled.PlayCircle, contentDescription = null, tint = Color.White, modifier = Modifier.size(44.dp))
    }
}

/** The attached photo or video above the message box; a video shows its first frame. */
@Composable
internal fun DMAttachmentThumbnail(uri: Uri, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val video = remember(uri) { DMVideo.isVideoMime(context.contentResolver.getType(uri)) }
    Box(modifier, contentAlignment = Alignment.Center) {
        AsyncImage(
            model = ImageRequest.Builder(context).data(uri)
                .apply { if (video) decoderFactory(VideoFrameDecoder.Factory()) }.build(),
            contentDescription = if (video) "Attached video" else "Attached image",
            contentScale = ContentScale.Crop,
            modifier = Modifier.matchParentSize(),
        )
        if (video) {
            Icon(Icons.Filled.PlayCircle, contentDescription = null, tint = Color.White, modifier = Modifier.size(22.dp))
        }
    }
}

/** Where a locked video tile stands. */
private sealed interface LockedVideoState {
    data object Waiting : LockedVideoState
    data class Loading(val got: Long, val total: Long) : LockedVideoState
    class Ready(val bytes: ByteArray) : LockedVideoState
    data object Failed : LockedVideoState
}

/** "12.4 MB" for a byte count. */
internal fun dmVideoSize(bytes: Long): String =
    if (bytes >= 1024 * 1024) "%.1f MB".format(bytes / (1024.0 * 1024.0)) else "${(bytes + 1023) / 1024} KB"

/**
 * A locked video (kind 15, [com.nostrvault.service.DMFile]) in a thread: its size, then a progress
 * ring while it arrives and opens, then the video itself, playing silently in the bubble. A small
 * one loads by itself; a bigger one (over [com.nostrvault.service.DMFileLoader.AUTO_SHOW_MAX], or of
 * unknown size) waits for a tap. Once playing, a tap opens the full-screen player ([onOpen]).
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
@Composable
internal fun DMLockedVideoTile(link: String, size: Dp, onOpen: () -> Unit) {
    val context = LocalContext.current
    val app = context.applicationContext
    val total = remember(link) { com.nostrvault.service.DMFile.parseFileLink(link)?.size }
    val auto = total != null && total <= com.nostrvault.service.DMFileLoader.AUTO_SHOW_MAX
    var state by androidx.compose.runtime.remember(link) { androidx.compose.runtime.mutableStateOf<LockedVideoState>(LockedVideoState.Waiting) }
    // Each tap to load (or try again) is a new try; a small video's first try is its own.
    var tries by androidx.compose.runtime.remember(link) { androidx.compose.runtime.mutableIntStateOf(if (auto) 1 else 0) }
    val current by DMOpenedVideo.current.collectAsState()

    androidx.compose.runtime.LaunchedEffect(link, tries) {
        if (tries == 0 || state is LockedVideoState.Ready) return@LaunchedEffect
        state = LockedVideoState.Loading(0, total ?: -1)
        state = try {
            val bytes = DMOpenedVideo.open(app, link) { got, all ->
                state = LockedVideoState.Loading(got, if (all > 0) all else total ?: -1)
            }
            LockedVideoState.Ready(bytes)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            LockedVideoState.Failed
        }
    }
    // Another video was opened: this one's bytes were let go, so its player goes too.
    if (state is LockedVideoState.Ready && current != link) {
        state = LockedVideoState.Waiting
        tries = 0
    }

    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .size(size)
            .background(Color.Black.copy(alpha = 0.85f))
            .clickable {
                when (state) {
                    is LockedVideoState.Ready -> onOpen()
                    LockedVideoState.Waiting, LockedVideoState.Failed -> tries++
                    is LockedVideoState.Loading -> Unit
                }
            }
            .semantics { contentDescription = "Video" },
    ) {
        when (val s = state) {
            is LockedVideoState.Ready -> {
                val player = remember(s) {
                    com.nostrvault.ui.components.buildBytesExoPlayer(app, s.bytes, playWhenReady = true).apply { volume = 0f }
                }
                androidx.compose.runtime.DisposableEffect(player) { onDispose { player.release() } }
                com.nostrvault.ui.components.VideoSurface(
                    player = player,
                    modifier = Modifier.matchParentSize(),
                    resizeMode = androidx.media3.ui.AspectRatioFrameLayout.RESIZE_MODE_ZOOM,
                )
            }
            is LockedVideoState.Loading -> {
                androidx.compose.foundation.layout.Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    if (s.total > 0) {
                        androidx.compose.material3.CircularProgressIndicator(
                            progress = { (s.got.toFloat() / s.total).coerceIn(0f, 1f) },
                            color = Color.White,
                        )
                    } else {
                        androidx.compose.material3.CircularProgressIndicator(color = Color.White)
                    }
                    androidx.compose.material3.Text(
                        text = if (s.total > 0) "${dmVideoSize(s.got)} of ${dmVideoSize(s.total)}" else dmVideoSize(s.got),
                        color = Color.White,
                        fontSize = androidx.compose.ui.unit.TextUnit(12f, androidx.compose.ui.unit.TextUnitType.Sp),
                        modifier = Modifier.padding(top = 8.dp),
                    )
                }
            }
            LockedVideoState.Waiting, LockedVideoState.Failed -> {
                androidx.compose.foundation.layout.Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(Icons.Filled.PlayCircle, contentDescription = null, tint = Color.White, modifier = Modifier.size(44.dp))
                    androidx.compose.material3.Text(
                        text = when {
                            state == LockedVideoState.Failed -> "Couldn't open this video. Tap to try again."
                            total != null -> dmVideoSize(total)
                            else -> "Tap to load"
                        },
                        color = Color.White,
                        fontSize = androidx.compose.ui.unit.TextUnit(12f, androidx.compose.ui.unit.TextUnitType.Sp),
                        modifier = Modifier.padding(top = 6.dp, start = 8.dp, end = 8.dp),
                    )
                }
            }
        }
    }
}
