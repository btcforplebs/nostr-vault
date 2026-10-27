package com.nostrvault.ui.components

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import com.nostrvault.ui.notification.LocalNotificationManager
import com.nostrvault.ui.screens.DeleteBlobConfirmDialog
import com.nostrvault.ui.screens.DeleteScope
import androidx.compose.ui.semantics.contentDescription
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.max

/**
 * Full-screen, swipeable viewer for a note's media. Opens at the tapped item and
 * pages horizontally across the note's images/videos, with pinch-to-zoom and
 * vertical drag-to-dismiss (matching the dedicated gallery viewer / iOS). Keeps
 * the lightweight mirror pill + close affordances of the old single-item dialog;
 * the mirror pill tracks whichever page is currently visible.
 *
 * Rendered as an activity-window overlay via [FullScreenMediaHost] — NOT a Dialog —
 * so Picture-in-Picture (which only captures the activity's own window) can show
 * the playing video. All chrome hides while the activity is in PiP.
 *
 * With an [origin], a photo zooms out of its spot in the feed and, on close
 * (swipe, back, or the X), back into it — iOS #117. It fades instead for a
 * video, a zoomed-in photo, a spot that has scrolled away, or Reduce Motion.
 * [onDismiss] runs once the close animation has landed.
 *
 * Audio pages play in [AudioPlayer], as iOS's MediaItemRenderer does; a
 * vertical drag closes video and audio pages as it does a photo. [copyLink]
 * adds a Copy link button (the profile viewer's, iOS ProfileView).
 */
@Composable
internal fun FullScreenMediaPager(
    urls: List<String>,
    initialIndex: Int,
    onDismiss: () -> Unit,
    origin: Long? = null,
    copyLink: Boolean = false,
    authors: List<String?> = emptyList(),
    viewModel: FeedMediaMirrorViewModel = hiltViewModel(),
) {
    val mirrorState by viewModel.state.collectAsState()
    val saveState by viewModel.saveState.collectAsState()
    val deleting by viewModel.deleting.collectAsState()
    // Long-press opens the delete bar (iOS FeedMediaViewer isDeleting); a
    // choice there asks first with the shared dialog.
    var showDeleteBar by remember { mutableStateOf(false) }
    var pendingDelete by remember { mutableStateOf<DeleteScope?>(null) }
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    val lane = LocalNotificationManager.current
    val isInPiP by VideoPiPBridge.isInPiP.collectAsState()
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current

    val pagerState = rememberPagerState(
        initialPage = initialIndex.coerceIn(0, urls.lastIndex),
        pageCount = { urls.size },
    )
    val currentUrl = urls[pagerState.currentPage]

    // Re-evaluate mirror status whenever the visible page changes (the ViewModel is
    // shared across the feed, so only one viewer is ever active).
    LaunchedEffect(currentUrl) {
        viewModel.onOpen(currentUrl)
        showDeleteBar = false
    }
    LaunchedEffect(pagerState.currentPage) { FullScreenMediaRouter.setPage(pagerState.currentPage) }

    // Drag-to-dismiss state, using the same visual formulas as MediaViewerScreen / iOS.
    val dragOffsetY = remember { Animatable(0f) }
    var currentScale by remember { mutableFloatStateOf(1f) }
    var accumulatedDragY by remember { mutableFloatStateOf(0f) }
    val dismissThresholdPx = with(density) { 120.dp.toPx() }

    val backgroundAlpha by remember {
        derivedStateOf { (1f - abs(dragOffsetY.value) / 300f).coerceIn(0f, 1f) }
    }
    val contentScale by remember {
        derivedStateOf { max(0.8f, 1f - abs(dragOffsetY.value) / 1000f) }
    }
    val overlayAlpha by remember {
        derivedStateOf { (1f - abs(dragOffsetY.value) / 100f).coerceIn(0f, 1f) }
    }

    // ── Zoom in from / out to the tapped photo ──────────────────────────
    // 0 = drawn over the source (or invisible, for a fade), 1 = full screen.
    val progress = remember { Animatable(0f) }
    // The transform at progress 0; null means cross-fade.
    var zoomFrom by remember { mutableStateOf<ZoomTransform?>(null) }
    var sourceRect by remember { mutableStateOf<ZoomRect?>(null) }
    var containerOrigin by remember { mutableStateOf(Offset.Zero) }
    var containerSize by remember { mutableStateOf(IntSize.Zero) }
    var closing by remember { mutableStateOf(false) }

    /** The zoom for the item at [page], or null when it should fade. */
    fun zoomFor(page: Int): Pair<ZoomTransform, ZoomRect>? {
        if (origin == null || Motion.isReduced || containerSize == IntSize.Zero) return null
        val url = urls.getOrNull(page) ?: return null
        if (isVideoUrl(url) || isAudioUrl(url)) return null
        val source = MediaZoomSources.get(MediaSourceKey(origin, page)) ?: return null
        if (!MediaZoomGeometry.isOnScreen(source.full, source.visible)) return null
        val rect = source.full.offset(-containerOrigin.x, -containerOrigin.y)
        val w = containerSize.width.toFloat()
        val h = containerSize.height.toFloat()
        // The viewer draws the image Fit; without a known ratio the source
        // box's own shape is the best guess (exact for a feed card).
        val aspect = MediaAspectCache.get(url) ?: (rect.width / rect.height)
        val fitted = MediaZoomGeometry.fit(aspect, w, h)
        return MediaZoomGeometry.transform(fitted, rect, source.crop) to rect
    }

    // Keyed on "laid out yet", not the size, so a rotation mid-zoom doesn't cancel it.
    val laidOut = containerSize != IntSize.Zero
    LaunchedEffect(laidOut) {
        if (!laidOut || closing || progress.value > 0f) return@LaunchedEffect
        val zoom = zoomFor(pagerState.currentPage)
        zoomFrom = zoom?.first
        sourceRect = zoom?.second
        if (zoom != null && origin != null) {
            FullScreenMediaRouter.setHiddenSource(MediaSourceKey(origin, pagerState.currentPage))
        }
        progress.animateTo(1f, if (zoom != null) Motion.panel() else Motion.fade())
        // Once full screen the black covers the source; show it again so a page
        // change can't leave a hole in the carousel underneath.
        FullScreenMediaRouter.setHiddenSource(null)
    }

    val close: () -> Unit = close@{
        if (closing) return@close
        closing = true
        val page = pagerState.currentPage
        val zoom = if (currentScale <= 1.05f) zoomFor(page) else null
        zoomFrom = zoom?.first
        sourceRect = zoom?.second
        if (zoom != null && origin != null) {
            FullScreenMediaRouter.setHiddenSource(MediaSourceKey(origin, page))
        }
        scope.launch {
            launch { dragOffsetY.animateTo(0f, if (zoom != null) Motion.panel() else Motion.fade()) }
            progress.animateTo(0f, if (zoom != null) Motion.panel() else Motion.fade())
            onDismiss()
        }
    }

    BackHandler(onBack = close)

    // Drag-to-dismiss, fed by the page's ZoomableBox (photo, video or audio).
    val onVerticalDrag: (Float) -> Unit = { deltaY ->
        if (currentScale <= 1.05f && !closing) {
            accumulatedDragY += deltaY
            scope.launch { dragOffsetY.snapTo(accumulatedDragY) }
        }
    }
    val onVerticalDragEnd: () -> Unit = {
        if (closing) {
            // The close animation owns the offset now.
        } else if (abs(accumulatedDragY) > dismissThresholdPx) {
            close()
        } else {
            scope.launch {
                dragOffsetY.animateTo(0f, Motion.snapBack())
            }
        }
        accumulatedDragY = 0f
    }

    val shown by remember { derivedStateOf { progress.value.coerceIn(0f, 1f) } }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .onGloballyPositioned {
                containerOrigin = it.positionInWindow()
                containerSize = it.size
            }
            .background(Color.Black.copy(alpha = backgroundAlpha * shown))
            // Swallow taps that no child consumed so they can't reach the UI beneath
            .pointerInput(Unit) { detectTapGestures { } },
    ) {
            HorizontalPager(
                state = pagerState,
                // Lock paging while a page is zoomed so pan doesn't flip pages.
                userScrollEnabled = currentScale <= 1.05f && !closing,
                modifier = Modifier
                    .fillMaxSize()
                    .graphicsLayer {
                        val from = zoomFrom
                        if (from == null) {
                            alpha = shown
                        } else {
                            val t = MediaZoomGeometry.interpolate(from, progress.value)
                            transformOrigin = TransformOrigin(0f, 0f)
                            scaleX = t.scale
                            scaleY = t.scale
                            translationX = t.translationX
                            translationY = t.translationY
                        }
                    }
                    .drawWithContent {
                        val from = zoomFrom
                        val src = sourceRect
                        if (from == null || src == null || progress.value >= 1f) {
                            drawContent()
                        } else {
                            // Clip to the source's shape at 0, opening to the full screen.
                            val clip = MediaZoomGeometry.lerpRect(
                                MediaZoomGeometry.toLocal(src, from),
                                ZoomRect(0f, 0f, size.width, size.height),
                                progress.value,
                            )
                            clipRect(clip.left, clip.top, clip.left + clip.width, clip.top + clip.height) {
                                this@drawWithContent.drawContent()
                            }
                        }
                    }
                    .graphicsLayer {
                        translationY = dragOffsetY.value
                        scaleX = contentScale
                        scaleY = contentScale
                    },
            ) { page ->
                val url = urls[page]
                if (isVideoUrl(url) || isAudioUrl(url)) {
                    // The same gestures as a photo (iOS): drag to close,
                    // long-press for the delete bar, and pinch / double-tap
                    // zoom on a video. A single tap shows or hides the
                    // player's controls, which zooming in hides.
                    val videoControls = remember(url) { VideoControls() }
                    ZoomableBox(
                        zoomable = isVideoUrl(url) && !isInPiP,
                        onScaleChanged = {
                            currentScale = it
                            videoControls.zoomed(it)
                        },
                        onVerticalDrag = onVerticalDrag,
                        onVerticalDragEnd = { onVerticalDragEnd() },
                        onLongPress = {
                            if (!closing && !deleting && viewModel.canDelete(url)) showDeleteBar = !showDeleteBar
                        },
                        onTap = if (isVideoUrl(url) && !isInPiP) videoControls::tap else null,
                        modifier = Modifier
                            .fillMaxSize()
                            .background(Color.Black),
                    ) {
                        // Only the visible page gets a player, to keep memory at one instance.
                        if (page == pagerState.currentPage) {
                            if (isAudioUrl(url)) {
                                AudioPlayer(
                                    uri = url,
                                    fileName = url.substringAfterLast('/').substringBefore('?').substringBefore('#'),
                                    modifier = Modifier.fillMaxSize(),
                                )
                            } else {
                                VideoPlayer(uri = url, modifier = Modifier.fillMaxSize(), controls = videoControls.shown)
                            }
                        }
                    }
                } else {
                    ZoomableImage(
                        model = url,
                        meshAuthor = authors.getOrNull(page),
                        contentDescription = null,
                        onScaleChanged = { currentScale = it },
                        onVerticalDrag = onVerticalDrag,
                        onVerticalDragEnd = { onVerticalDragEnd() },
                        onLongPress = {
                            if (!closing && !deleting && viewModel.canDelete(url)) showDeleteBar = !showDeleteBar
                        },
                        modifier = Modifier.fillMaxSize(),
                    )
                }
            }

            if (!isInPiP) {
                IconButton(
                    onClick = close,
                    modifier = Modifier
                        .align(Alignment.TopStart)
                        .statusBarsPadding()
                        .padding(8.dp)
                        .size(40.dp)
                        .graphicsLayer { alpha = overlayAlpha * shown }
                        .background(Color.Black.copy(alpha = 0.4f), CircleShape),
                ) {
                    Icon(
                        imageVector = NostrVaultIcons.Dismiss,
                        contentDescription = "Close",
                        tint = Color.White,
                    )
                }
            }

            // Top row, like iOS (PR #120): Save, then Mirror / Mirrored, one-word
            // labels. Messages go out as system toasts: the in-app pills draw
            // under this overlay.
            if (!isInPiP) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .statusBarsPadding()
                        .padding(8.dp)
                        .graphicsLayer { alpha = overlayAlpha * shown },
                ) {
                    if (copyLink && isShareableMediaUrl(currentUrl)) {
                        IconButton(
                            onClick = {
                                clipboard.setText(AnnotatedString(currentUrl))
                                lane.showFeedback("Link copied", NostrVaultIcons.LinkIcon)
                            },
                            modifier = Modifier
                                .size(36.dp)
                                .background(Color.Black.copy(alpha = 0.6f), CircleShape),
                        ) {
                            Icon(NostrVaultIcons.Copy, "Copy link", tint = Color.White, modifier = Modifier.size(18.dp))
                        }
                    }
                    // A photo or video, as iOS offers Save to Photos; not audio.
                    if (!isAudioUrl(currentUrl)) {
                        SaveToGalleryPill(
                            state = saveState,
                            onSave = {
                                viewModel.saveToGallery(currentUrl)
                            },
                        )
                    }
                    if (viewModel.canMirror) {
                        MirrorToBlossomPill(
                            state = mirrorState,
                            onMirror = { viewModel.mirror(currentUrl) },
                        )
                    }
                }
            }

            if (showDeleteBar && !isInPiP) {
                FeedMediaDeleteBar(
                    deleting = deleting,
                    onDeleteFromMirrors = { pendingDelete = DeleteScope.MIRRORS },
                    onDeleteEverywhere = { pendingDelete = DeleteScope.EVERYWHERE },
                    onCancel = { showDeleteBar = false },
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .navigationBarsPadding()
                        .padding(16.dp)
                        .padding(bottom = if (urls.size > 1) 24.dp else 0.dp),
                )
            }

            pendingDelete?.let { scope ->
                val url = currentUrl
                val postCount = remember(scope, url) {
                    if (scope == DeleteScope.EVERYWHERE) viewModel.postsUsing(url) else 0
                }
                fun confirm(deletePosts: Boolean) {
                    pendingDelete = null
                    // The bar stays up showing "Deleting…" until the result is in.
                    viewModel.delete(
                        url = url,
                        scope = scope,
                        deletePosts = deletePosts,
                        onDone = { showDeleteBar = false },
                        onAllGone = close,
                    )
                }
                DeleteBlobConfirmDialog(
                    scope = scope,
                    postCount = postCount,
                    onConfirm = { confirm(deletePosts = false) },
                    onConfirmWithPosts = { confirm(deletePosts = true) },
                    onDismiss = { pendingDelete = null },
                )
            }

            // Page-position bar, only when the note carries more than one item.
            if (urls.size > 1 && !isInPiP) {
                PagePositionBar(
                    count = urls.size,
                    index = pagerState.currentPage,
                    track = Color.White.copy(alpha = 0.35f),
                    lit = Color.White,
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .navigationBarsPadding()
                        .padding(bottom = 24.dp)
                        .graphicsLayer { alpha = overlayAlpha * shown },
                )
            }
    }
}

/** The bar a long-press opens: Delete from mirrors, Delete everywhere, Cancel. iOS FeedMediaViewer. */
@Composable
private fun FeedMediaDeleteBar(
    deleting: Boolean,
    onDeleteFromMirrors: () -> Unit,
    onDeleteEverywhere: () -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val red = Color(0xFFE53935)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .background(Color.Black.copy(alpha = 0.8f))
            .padding(horizontal = 8.dp, vertical = 4.dp),
    ) {
        if (deleting) {
            CircularProgressIndicator(modifier = Modifier.size(18.dp), color = Color.White, strokeWidth = 2.dp)
            Spacer(Modifier.width(8.dp))
            Text("Deleting…", color = Color.White, fontSize = 14.sp)
            Spacer(Modifier.weight(1f))
        } else {
            TextButton(onClick = onDeleteFromMirrors) {
                Icon(NostrVaultIcons.Cloud, contentDescription = null, tint = red, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(4.dp))
                Text("Delete from mirrors", color = red, fontSize = 13.sp)
            }
            TextButton(onClick = onDeleteEverywhere) {
                Icon(NostrVaultIcons.Delete, contentDescription = null, tint = red, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(4.dp))
                Text("Delete everywhere", color = red, fontSize = 13.sp)
            }
            Spacer(Modifier.weight(1f))
        }
        TextButton(onClick = onCancel) { Text("Cancel", color = Color.White, fontSize = 13.sp) }
    }
}
