package com.nostrvault.ui.components

import com.nostrvault.ui.components.MeshMediaStatusOverlay
import androidx.compose.foundation.background
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImagePainter
import coil.compose.rememberAsyncImagePainter
import coil.request.ImageRequest
import com.nostrvault.data.model.BlossomUri
import com.nostrvault.fips.MeshMediaStatus
import com.nostrvault.fips.meshAuthor
import androidx.compose.ui.semantics.contentDescription
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.delay

private val VIDEO_EXTENSIONS = setOf("mp4", "mov", "webm", "avi", "mkv", "m4v")

internal fun isVideoUrl(url: String): Boolean {
    val ext = url.substringAfterLast('.').substringBefore('?').lowercase()
    return ext in VIDEO_EXTENSIONS
}

private val AUDIO_EXTENSIONS = setOf("mp3", "m4a", "wav", "ogg", "aac", "flac", "opus")

/** An audio file: it plays from a card, not in the photo/video viewer. */
internal fun isAudioUrl(url: String): Boolean {
    val ext = url.substringAfterLast('.').substringBefore('?').substringBefore('#').lowercase()
    return ext in AUDIO_EXTENSIONS
}

@Composable
fun MediaPreviewRow(
    urls: List<String>,
    /** The note's tags, read for NIP-92 `imeta dim` so the box is right first time. */
    tags: List<List<String>> = emptyList(),
    /** Play videos inline (muted, looping, one at a time) instead of a poster. */
    autoplayVideos: Boolean = false,
    /** The note's author, whose vault may serve this media over the FIPS mesh. */
    author: String? = null,
    modifier: Modifier = Modifier,
) {
    // Audio plays from its own card on the app-wide player; the rest open
    // the viewer. iOS: FeedAudioCard.
    val (audio, visual) = remember(urls) { urls.partition(::isAudioUrl) }
    if (audio.isEmpty()) {
        VisualMediaPreview(visual, tags, autoplayVideos, author, modifier)
        return
    }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (visual.isNotEmpty()) VisualMediaPreview(visual, tags, autoplayVideos, author)
        audio.forEach { com.nostrvault.ui.screens.music.AudioFileCard(it) }
    }
}

@Composable
private fun VisualMediaPreview(
    urls: List<String>,
    tags: List<List<String>>,
    autoplay: Boolean,
    author: String?,
    modifier: Modifier = Modifier,
) {
    // One id per row, so the viewer can find the photo it opened from.
    val origin = remember { MediaZoomSources.newOrigin() }
    if (urls.size == 1) {
        SingleMediaPreview(
            url = urls.first(),
            tags = tags,
            sourceKey = MediaSourceKey(origin, 0),
            onMediaClick = { FullScreenMediaRouter.open(urls, 0, origin, authors = urls.map { author }) },
            autoplay = autoplay,
            author = author,
            modifier = modifier,
        )
    } else {
        MediaCarousel(
            urls = urls,
            tags = tags,
            origin = origin,
            onMediaClick = { index -> FullScreenMediaRouter.open(urls, index, origin, authors = urls.map { author }) },
            autoplay = autoplay,
            author = author,
            modifier = modifier,
        )
    }
}

@Composable
private fun SingleMediaPreview(
    url: String,
    tags: List<List<String>>,
    sourceKey: MediaSourceKey,
    onMediaClick: (String) -> Unit,
    autoplay: Boolean = false,
    author: String? = null,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val isVideo = isVideoUrl(url)

    // Size to the media's natural aspect ratio — capped at 400dp landscape /
    // 600dp portrait. Matches iOS FeedMediaView (Fit, no crop).
    val painter = rememberAsyncImagePainter(
        model = ImageRequest.Builder(context)
            .data(remember(url, tags) { feedImageModel(tags, url) })
            .meshAuthor(author)
            .size(800)
            .crossfade(100)
            .build(),
    )
    val decodedRatio = (painter.state as? AsyncImagePainter.State.Success)?.let {
        val size = painter.intrinsicSize
        if (size.width > 0f && size.height > 0f) size.width / size.height else null
    }

    // What the author told us, or what an earlier decode taught us. With either,
    // the box is right before the bytes arrive and nothing below this note moves.
    val hintedRatio = remember(url, tags) { knownAspectRatio(tags, url) }

    // Remember what we decode so this URL never shifts the feed again, however
    // many times the LazyColumn recycles the row.
    LaunchedEffect(url, decodedRatio) {
        decodedRatio?.let { MediaAspectCache.put(url, it) }
    }

    // The hint wins while it exists, so the height does not change *again* when
    // the decode lands and reports a ratio a rounded `dim` disagrees with by a
    // pixel. A video's hint is overruled when it has the frame the wrong way
    // round (a phone's rotated portrait video, see videoBoxRatio).
    val ratio = if (isVideo) videoBoxRatio(hintedRatio, decodedRatio) else hintedRatio ?: decodedRatio
    val screenHeightDp = LocalConfiguration.current.screenHeightDp

    val loaded = painter.state is AsyncImagePainter.State.Success
    // A photo that failed says so (MediaFailedPlaceholder); a video keeps its play icon.
    // A blossom: video whose file no server had says so as well.
    val failed = (!isVideo || BlossomUri.isUri(url)) && painter.state is AsyncImagePainter.State.Error
    val meshPhases by MeshMediaStatus.phases.collectAsState()

    BoxWithConstraints(modifier = modifier.fillMaxWidth()) {
        val cap = when {
            // A portrait video stands at its own shape, but never fills the screen.
            ratio != null && ratio < 1f && isVideo -> feedVideoMaxHeightDp(screenHeightDp).dp
            ratio != null && ratio < 1f -> 600.dp
            else -> 400.dp
        }
        val displayHeight = when {
            ratio != null -> minOf(maxWidth / ratio, cap)
            failed -> maxWidth * 9f / 16f
            else -> 200.dp
        }
        // Square to its edges, with no rounded frame, and grey only while
        // the photo loads (iOS #286, Logen: screen room).
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .fillMaxWidth()
                .height(displayHeight)
                .mediaZoomSource(sourceKey)
                .clipToBounds()
                .then(if (loaded) Modifier else Modifier.background(TertiaryGroupedBg))
                .clickable { onMediaClick(url) },
        ) {
            BlurHashPreview(
                url = url,
                tags = tags,
                ratio = ratio,
                loaded = loaded,
            )
            Image(
                painter = painter,
                contentDescription = null,
                contentScale = ContentScale.Fit,
                modifier = Modifier.fillMaxSize(),
            )
            if (!loaded) {
                MeshMediaStatusOverlay(url = feedImageModel(tags, url), video = isVideo, modifier = Modifier.matchParentSize())
            }
            // A broken photo the mesh isn't answering for (its overlay says so itself).
            if (failed && MeshMediaStatus.phaseFor(meshPhases, feedImageModel(tags, url)) == null) {
                MediaFailedPlaceholder(url = url)
            }
            if (isVideo && autoplay && !failed) {
                InlineFeedVideo(key = sourceKey, url = url, modifier = Modifier.matchParentSize())
            } else if (isVideo && !failed) {
                Icon(
                    imageVector = NostrVaultIcons.PlayCircle,
                    contentDescription = "Video",
                    tint = Color.White.copy(alpha = 0.85f),
                    modifier = Modifier.size(32.dp),
                )
            }
        }
    }
}

/**
 * What the feed asks Coil for to show [url]: the URL itself, except for a video
 * whose `imeta` names a poster image (`image`, or the older `thumb`), which is
 * a small JPEG instead of a frame read out of the video.
 */
internal fun feedImageModel(tags: List<List<String>>, url: String): String =
    if (isVideoUrl(url)) {
        (imetaField(tags, url, "image") ?: imetaField(tags, url, "thumb"))
            ?.takeIf { isWebUrl(it) } ?: url
    } else url

/** A poster comes from the note's author, so only a web URL is fetched, never file: or content:. */
private fun isWebUrl(s: String): Boolean =
    s.startsWith("https://", ignoreCase = true) || s.startsWith("http://", ignoreCase = true)

/**
 * What a photo shows before its pixels arrive: the NIP-92 `blurhash` preview,
 * stretched over exactly the rect the `Fit` image will occupy. Without a
 * blurhash it draws nothing and the card fill shows, as before. iOS parity:
 * `MediaLoadingPlaceholder`.
 */
@Composable
internal fun BlurHashPreview(
    url: String,
    tags: List<List<String>>,
    ratio: Float?,
    loaded: Boolean,
) {
    val preview = remember(url, tags) {
        BlurHash.bitmap(imetaField(tags, url, "blurhash"))?.asImageBitmap()
    } ?: return
    // Stay under the arriving image until its 100ms crossfade has finished;
    // dropping the preview at once would flash the empty card between the two.
    var gone by remember(url) { mutableStateOf(false) }
    LaunchedEffect(loaded) {
        if (loaded) {
            delay(250)
            gone = true
        }
    }
    if (gone) return
    Image(
        bitmap = preview,
        contentDescription = null,
        contentScale = ContentScale.FillBounds,
        modifier = if (ratio != null) Modifier.aspectRatio(ratio) else Modifier.fillMaxSize(),
    )
}
