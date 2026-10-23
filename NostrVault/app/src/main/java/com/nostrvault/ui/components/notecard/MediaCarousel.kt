package com.nostrvault.ui.components

import com.nostrvault.ui.components.MeshMediaStatusOverlay
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import coil.request.ImageRequest
import com.nostrvault.fips.meshAuthor
import androidx.compose.ui.semantics.contentDescription
import com.nostrvault.ui.theme.*

@Composable
internal fun MediaCarousel(
    urls: List<String>,
    tags: List<List<String>>,
    origin: Long,
    onMediaClick: (Int) -> Unit,
    autoplay: Boolean = false,
    author: String? = null,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val pagerState = rememberPagerState(pageCount = { urls.size })

    // Follow the full-screen viewer as it pages, so closing it on the third
    // photo zooms back into a carousel showing the third photo.
    val viewerPosition by FullScreenMediaRouter.position.collectAsState()
    LaunchedEffect(viewerPosition) {
        val p = viewerPosition ?: return@LaunchedEffect
        if (p.origin == origin && p.index in urls.indices && p.index != pagerState.currentPage) {
            pagerState.scrollToPage(p.index)
        }
    }

    // A pager has one height for every page, so the ratio comes from the first
    // image — the one you see before you swipe — and the first page fits it
    // exactly. Every page fills the frame edge to edge, cropping a page whose
    // shape differs, rather than sitting letterboxed in a grey box (iOS #286,
    // Logen 2026-10-05).
    //
    // This used to be a hard `aspectRatio(4f / 3f)`, which cropped even the
    // first photo: a portrait one displayed whole when posted alone lost its
    // top and bottom the moment a second image joined it.
    val firstRatio = remember(urls, tags) { knownAspectRatio(tags, urls.first()) }
    // A first-page video takes the shape of its decoded frame when the hint has it the wrong way
    // round or is missing: with the 4:3 default a portrait video was cut down to a landscape strip.
    var firstDecoded by remember(urls) { mutableStateOf<Float?>(null) }
    val firstIsVideo = isVideoUrl(urls.first())
    val shapeRatio = if (firstIsVideo) videoBoxRatio(firstRatio, firstDecoded) else firstRatio
    val config = androidx.compose.ui.platform.LocalConfiguration.current
    // A portrait video page is no taller than one alone in the feed (feedVideoMaxHeightDp).
    val minRatio = if (firstIsVideo) {
        maxOf(2f / 3f, config.screenWidthDp / feedVideoMaxHeightDp(config.screenHeightDp))
    } else 2f / 3f
    val pagerRatio = (shapeRatio ?: (4f / 3f)).coerceIn(minRatio, maxOf(minRatio, 16f / 9f))

    Column(modifier = modifier) {
        HorizontalPager(
            state = pagerState,
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(pagerRatio)
                .clipToBounds(),
        ) { page ->
            val url = urls[page]
            var loaded by remember(url) { mutableStateOf(false) }
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .fillMaxSize()
                    .mediaZoomSource(MediaSourceKey(origin, page))
                    .then(if (loaded) Modifier else Modifier.background(TertiaryGroupedBg))
                    .clickable { onMediaClick(page) },
            ) {
                BlurHashPreview(
                    url = url,
                    tags = tags,
                    ratio = remember(url, tags) { knownAspectRatio(tags, url) },
                    loaded = loaded,
                )
                AsyncImage(
                    model = ImageRequest.Builder(context)
                        .data(remember(url, tags) { feedImageModel(tags, url) })
                        .meshAuthor(author)
                        .size(800)
                        .crossfade(100)
                        .build(),
                    contentDescription = null,
                    // Photos fill the frame edge to edge (iOS #286). A video is shown whole: its
                    // player fits, and a cropped poster would show a different picture.
                    contentScale = if (isVideoUrl(url)) ContentScale.Fit else ContentScale.Crop,
                    onSuccess = { result ->
                        loaded = true
                        val d = result.result.drawable
                        if (d.intrinsicWidth > 0 && d.intrinsicHeight > 0) {
                            val ratio = d.intrinsicWidth.toFloat() / d.intrinsicHeight.toFloat()
                            MediaAspectCache.put(url, ratio)
                            if (page == 0) firstDecoded = ratio
                        }
                    },
                    modifier = Modifier.fillMaxSize(),
                )
                if (!loaded) {
                    MeshMediaStatusOverlay(url = feedImageModel(tags, url), video = isVideoUrl(url), modifier = Modifier.matchParentSize())
                }
                if (isVideoUrl(url) && autoplay && page == pagerState.currentPage) {
                    // Only the page in view is a candidate; the others keep a poster.
                    InlineFeedVideo(
                        key = MediaSourceKey(origin, page),
                        url = url,
                        modifier = Modifier.matchParentSize(),
                    )
                } else if (isVideoUrl(url)) {
                    Icon(
                        imageVector = NostrVaultIcons.PlayCircle,
                        contentDescription = "Video",
                        tint = Color.White.copy(alpha = 0.85f),
                        modifier = Modifier.size(32.dp),
                    )
                }
            }
        }

        // Page-position bar
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 8.dp),
        ) {
            PagePositionBar(
                count = urls.size,
                index = pagerState.currentPage,
                track = SecondaryText.copy(alpha = 0.25f),
                lit = LocalNostrVaultColors.current.primary,
            )
        }
    }
}

/**
 * Thin position bar for a multi-image note: a hairline track with one slot per item and
 * the current slot lit, sliding as the pager settles. Mirrors iOS PagePositionBar.
 */
@Composable
internal fun PagePositionBar(
    count: Int,
    index: Int,
    track: Color,
    lit: Color,
    modifier: Modifier = Modifier,
) {
    if (count < 2) return
    // Slots shrink as the count grows so a long post still fits under a narrow card.
    val slot = (140f / count).coerceIn(8f, 18f).dp
    val clamped = index.coerceIn(0, count - 1)
    val offset by androidx.compose.animation.core.animateDpAsState(
        targetValue = slot * clamped,
        label = "pagePositionBar",
    )
    Box(
        modifier = modifier
            .size(width = slot * count, height = 2.5.dp)
            .clip(RoundedCornerShape(50))
            .background(track),
    ) {
        Box(
            modifier = Modifier
                .offset(x = offset)
                .size(width = slot, height = 2.5.dp)
                .clip(RoundedCornerShape(50))
                .background(lit),
        )
    }
}
